"""Adversarial API checks: isolation, immutable roles, protected media and exports.

Uses the shared ``client`` fixture with a seeded, disposable database.
"""
import base64
import csv
import io
import zipfile
from datetime import datetime, timedelta, timezone
from xml.etree import ElementTree

import pytest
from PIL import Image
from sqlalchemy import select
from starlette.websockets import WebSocketDisconnect

from app.models import AuthSession
from app.security import token_hash


@pytest.fixture
def security_context(client):
    sessions = {}

    def login(name):
        if name not in sessions:
            response = client.post('/api/auth/login', json={'login': name, 'pin': '1234'})
            assert response.status_code == 200, response.text
            sessions[name] = response.json()
        return sessions[name]

    def headers(name):
        return {'Authorization': f"Bearer {login(name)['token']}"}

    def create(worker='worker', title='Проверка изоляции доступа'):
        reference = client.get('/api/reference', headers=headers('master')).json()
        equipment = reference['equipment'][0]
        body = {
            'title': title,
            'description': 'Контрольная запись для проверки прав доступа.',
            'work_type': 'planned',
            'area_id': equipment['area_id'],
            'equipment_id': equipment['id'],
            'assignee_id': login(worker)['user']['id'],
            'priority': 'normal',
            'deadline': (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat(),
            'normal_hours': 2,
        }
        response = client.post('/api/orders', headers=headers('master'), json=body)
        assert response.status_code in (200, 201), response.text
        return response.json(), body

    return login, headers, create


def assert_no_secret_fields(value):
    if isinstance(value, dict):
        assert not {'pin', 'pin_hash', 'token_hash', 'password', 'password_hash'} & value.keys()
        for child in value.values():
            assert_no_secret_fields(child)
    elif isinstance(value, list):
        for child in value:
            assert_no_secret_fields(child)


def test_worker_scope_cannot_be_widened_by_query_or_order_id(client, security_context):
    login, headers, create = security_context
    own, _ = create()
    other, _ = create('worker2')
    result = client.get('/api/orders?limit=1000', headers=headers('worker'))
    assert result.status_code == 200
    assert any(order['id'] == own['id'] for order in result.json())
    assert all(order['assignee_id'] == login('worker')['user']['id'] for order in result.json())
    filtered = client.get(
        f"/api/orders?assignee_id={login('worker2')['user']['id']}", headers=headers('worker')
    )
    assert filtered.status_code in (200, 403)
    if filtered.status_code == 200:
        assert filtered.json() == []
    assert client.get(f"/api/orders/{other['id']}", headers=headers('worker')).status_code == 403
    assert client.patch(
        f"/api/orders/{own['id']}", headers=headers('worker'),
        json={'assignee_id': login('worker2')['user']['id']},
    ).status_code == 403
    unchanged = client.get(f"/api/orders/{own['id']}", headers=headers('master')).json()
    assert unchanged['assignee_id'] == login('worker')['user']['id']


def test_manager_has_no_mutation_path(client, security_context):
    _, headers, create = security_context
    order, body = create()
    path = f"/api/orders/{order['id']}"
    attempts = [
        client.post('/api/orders', headers=headers('manager'), json=body),
        client.patch(path, headers=headers('manager'), json={'priority': 'emergency'}),
        client.post(path + '/transition', headers=headers('manager'), json={
            'action': 'cancel', 'reason': 'Попытка отмены руководителем',
        }),
        client.post(path + '/complete', headers=headers('manager'), json={
            'work_done': 'Проверка запрета выполнения руководителем',
            'fault_code_id': 1, 'materials': [],
        }),
        client.post('/api/reference/areas', headers=headers('manager'), json={'name': 'Запрет изменения'}),
        client.patch('/api/reference/areas/1', headers=headers('manager'), json={'name': 'Запрет изменения'}),
    ]
    assert [response.status_code for response in attempts] == [403] * len(attempts), [r.text for r in attempts]
    current = client.get(path, headers=headers('master')).json()
    assert current['status'] == 'issued' and current['priority'] == 'normal'
    assert len(current['events']) == len(order['events'])


def test_public_responses_never_expose_authentication_secrets(client, security_context):
    login, headers, _ = security_context
    assert_no_secret_fields(login('admin')['user'])
    for path in ('/api/auth/me', '/api/reference', '/api/employees', '/api/orders', '/api/notifications'):
        response = client.get(path, headers=headers('admin'))
        assert response.status_code == 200, response.text
        assert_no_secret_fields(response.json())
    for invalid in ('missing-session', login('worker')['token'] + 'changed'):
        response = client.get('/api/orders', headers={'Authorization': f'Bearer {invalid}'})
        assert response.status_code == 401
    assert client.post('/api/auth/login', json={'login': 'worker', 'pin': '0000'}).status_code == 401


def test_expired_session_is_rejected_by_http_and_existing_websocket(client, security_context):
    login, headers, _ = security_context
    session = login('worker')
    with client.websocket_connect(f"/api/ws?token={session['token']}") as websocket:
        assert websocket.receive_json()['type'] == 'connected'
        with client.app.state.sessions() as db:
            stored = db.scalar(select(AuthSession).where(AuthSession.token_hash == token_hash(session['token'])))
            stored.expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
            db.commit()
        assert client.get('/api/orders', headers=headers('worker')).status_code == 401
        websocket.send_text('ping')
        with pytest.raises(WebSocketDisconnect) as closed:
            websocket.receive_json()
        assert closed.value.code == 1008
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(f"/api/ws?token={session['token']}"):
            pass


def test_idle_websocket_rechecks_revoked_session_without_client_ping(client, security_context, monkeypatch):
    login, headers, _ = security_context
    monkeypatch.setattr('app.main.WS_AUTH_RECHECK_SECONDS', 0.02)
    session = login('worker')
    with client.websocket_connect(f"/api/ws?token={session['token']}") as websocket:
        assert websocket.receive_json()['type'] == 'connected'
        response = client.post('/api/auth/logout', headers=headers('worker'))
        assert response.status_code == 200
        # Deliberately send no messages: revocation must be checked by the server.
        with pytest.raises(WebSocketDisconnect) as closed:
            websocket.receive_json()
        assert closed.value.code == 1008


def test_photo_bytes_require_permission_for_the_owning_order(client, security_context):
    _, headers, create = security_context
    order, _ = create()
    image_buffer = io.BytesIO()
    Image.new('RGB', (8, 8), '#336699').save(image_buffer, format='PNG')
    image = image_buffer.getvalue()
    path = f"/api/orders/{order['id']}/photos"
    response = client.post(path, headers=headers('worker'), data={'kind': 'before'},
                           files={'file': ('evidence.png', image, 'image/png')})
    assert response.status_code in (200, 201), response.text
    photo_url = response.json()['url']
    assert client.get(photo_url).status_code == 401
    assert client.get(photo_url, headers=headers('worker2')).status_code == 403
    assert client.get(photo_url, headers=headers('worker')).content.startswith(b'\xff\xd8')
    for role in ('manager', 'worker2'):
        rejected = client.post(path, headers=headers(role), data={'kind': 'after'},
                               files={'file': ('evidence.png', image, 'image/png')})
        assert rejected.status_code == 403, rejected.text
    detail = client.get(f"/api/orders/{order['id']}", headers=headers('master')).json()
    assert len(detail['photos']) == 1


def test_malformed_png_is_rejected_without_internal_error_or_partial_upload(client, security_context):
    _, headers, create = security_context
    order, _ = create()
    malformed_png = base64.b64decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='
    )
    response = client.post(f"/api/orders/{order['id']}/photos", headers=headers('worker'),
                           data={'kind': 'before'}, files={'file': ('bad-crc.png', malformed_png, 'image/png')})
    assert response.status_code == 422, response.text
    detail = client.get(f"/api/orders/{order['id']}", headers=headers('master')).json()
    assert detail['photos'] == []
    assert len(detail['events']) == len(order['events'])


@pytest.mark.parametrize('title', ['=HYPERLINK("https://example.invalid","click")', '+1+1', '-1+1', '@SUM(1,2)'])
def test_export_treats_user_titles_as_text(client, security_context, title):
    _, headers, create = security_context
    order, _ = create(title=title)
    csv_response = client.get('/api/reports/export?format=csv', headers=headers('master'))
    assert csv_response.status_code == 200
    text = csv_response.content.decode('utf-8-sig')
    rows = list(csv.reader(io.StringIO(text), delimiter=';' if ';' in text.splitlines()[0] else ','))
    row = next(row for row in rows if order['number'] in row)
    # Prefixing an apostrophe makes spreadsheet-looking values inert after import.
    assert "'" + title in row

    xlsx_response = client.get('/api/reports/export?format=xlsx', headers=headers('master'))
    assert xlsx_response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(xlsx_response.content)) as workbook:
        sheets = [name for name in workbook.namelist() if name.startswith('xl/worksheets/') and name.endswith('.xml')]
        assert sheets
        all_text = []
        for name in sheets:
            root = ElementTree.fromstring(workbook.read(name))
            assert not any(node.tag.rsplit('}', 1)[-1] == 'f' for node in root.iter()), 'Untrusted values became XLSX formulae'
            all_text.extend(root.itertext())
        assert order['number'] in all_text
        assert "'" + title in all_text


def test_invalid_reference_update_is_atomic_and_cannot_overwrite_identifiers(client, security_context):
    _, headers, _ = security_context
    before = client.get('/api/reference', headers=headers('admin')).json()
    material = before['materials'][0]
    response = client.patch(f"/api/reference/materials/{material['id']}", headers=headers('admin'),
                            json={'id': 999999, 'name': 'Недопустимая замена идентификатора'})
    assert response.status_code == 422, response.text
    equipment = before['equipment'][0]
    response = client.patch(f"/api/reference/equipment/{equipment['id']}", headers=headers('admin'),
                            json={'area_id': 999999})
    assert response.status_code == 422, response.text
    after = client.get('/api/reference', headers=headers('admin')).json()
    assert next(item for item in after['materials'] if item['id'] == material['id']) == material
    assert next(item for item in after['equipment'] if item['id'] == equipment['id']) == equipment


def test_notification_read_operation_cannot_target_another_worker(client, security_context):
    _, headers, create = security_context
    order, _ = create('worker2')
    notifications = client.get('/api/notifications', headers=headers('worker2')).json()
    notification = next(item for item in notifications if item['order_id'] == order['id'])
    response = client.post(f"/api/notifications/{notification['id']}/read", headers=headers('worker'))
    assert response.status_code in (403, 404), response.text
    after = client.get('/api/notifications', headers=headers('worker2')).json()
    assert next(item for item in after if item['id'] == notification['id'])['read'] is False
