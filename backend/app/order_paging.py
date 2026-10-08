"""Additive live-window pagination; a cursor never grants order access."""
import base64
import hashlib
import hmac
import json
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import and_, case, func, or_, select

from .models import Area, Employee, Equipment, Order, OrderAssignment, OrderAssignmentParticipant
from .services import EXECUTION_FINISHED, QUEUE_PRIORITIES, TERMINAL, aware, iso

CURSOR_ERROR = "Курсор не подходит к текущей выборке. Обновите список."


def fingerprint(user, filters):
    encoded = json.dumps({"user": user.id, "role": user.role, "query": filters},
        sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _b64encode(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _b64decode(value):
    decoded = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
    if _b64encode(decoded) != value:
        raise ValueError("noncanonical_cursor")
    return decoded


def encode_cursor(query_fingerprint, ceiling, last, session_hash):
    payload = json.dumps({"v": 1, "q": query_fingerprint, "ceiling": ceiling, "last": last},
        sort_keys=True, separators=(",", ":")).encode("utf-8")
    signature = hmac.digest(bytes.fromhex(session_hash), payload, "sha256")
    return _b64encode(payload) + "." + _b64encode(signature)


def decode_cursor(cursor, query_fingerprint, sort, session_hash):
    try:
        payload_text, signature_text = cursor.split(".")
        payload, signature = _b64decode(payload_text), _b64decode(signature_text)
        if not hmac.compare_digest(signature, hmac.digest(bytes.fromhex(session_hash), payload, "sha256")):
            raise ValueError("cursor_signature")
        result = json.loads(payload)
        if not isinstance(result, dict) or set(result) != {"v", "q", "ceiling", "last"}:
            raise ValueError("cursor_shape")
        if type(result["v"]) is not int or result["v"] != 1 or result["q"] != query_fingerprint:
            raise ValueError("cursor_scope")
        ceiling, last = result["ceiling"], result["last"]
        if type(ceiling) is not int or not 0 < ceiling < 2 ** 63:
            raise ValueError("cursor_ceiling")
        if not isinstance(last, list) or len(last) != (3 if sort == "priority" else 2):
            raise ValueError("cursor_tuple")
        if type(last[-1]) is not int or not 0 < last[-1] <= ceiling:
            raise ValueError("cursor_id")
        if sort == "priority" and (type(last[0]) is not int or last[0] not in QUEUE_PRIORITIES.values()):
            raise ValueError("cursor_priority")
        timestamp = last[-2]
        if not isinstance(timestamp, str) or len(timestamp) > 40:
            raise ValueError("cursor_time")
        parsed = datetime.fromisoformat(timestamp)
        if parsed.tzinfo is None or iso(parsed.astimezone(timezone.utc)) != timestamp:
            raise ValueError("cursor_time")
        last[-2] = parsed
        return ceiling, last
    except (ValueError, TypeError, KeyError, UnicodeError, OverflowError):
        raise HTTPException(422, CURSOR_ERROR) from None


def broad_search(db, query, search):
    """Literal substring over display fields and the current frozen roster."""
    if not search:
        return query
    escaped = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    needle = "%" + escaped + "%"
    def matches(column):
        if db.bind.dialect.name == "sqlite":
            return func.naryad_lower(column).like(needle, escape="\\")
        return column.ilike(needle, escape="\\")
    current_sequence = select(func.max(OrderAssignment.sequence)).where(
        OrderAssignment.order_id == Order.id).correlate(Order).scalar_subquery()
    participant = select(OrderAssignmentParticipant.id).join(OrderAssignment,
        OrderAssignment.id == OrderAssignmentParticipant.assignment_id).where(
        OrderAssignment.order_id == Order.id, OrderAssignment.sequence == current_sequence,
        OrderAssignment.assignee_id == Order.assignee_id,
        OrderAssignment.brigade_id.is_not_distinct_from(Order.brigade_id),
        OrderAssignment.assigned_at == Order.assigned_at,
        matches(OrderAssignmentParticipant.name)).exists()
    return query.where(or_(matches(Order.number), matches(Order.title), matches(Order.description),
        select(Equipment.id).where(Equipment.id == Order.equipment_id, matches(Equipment.name)).exists(),
        select(Area.id).where(Area.id == Order.area_id, matches(Area.name)).exists(),
        select(Employee.id).where(Employee.id == Order.assignee_id, matches(Employee.name)).exists(), participant))


def apply_scope(query, scope, focus, now):
    if scope == "active":
        query = query.where(Order.status.notin_(TERMINAL))
    elif scope == "closed":
        query = query.where(Order.status.in_(TERMINAL))
    if focus == "overdue":
        query = query.where(Order.status.notin_(EXECUTION_FINISHED), Order.deadline < now)
    elif focus == "emergency":
        query = query.where(Order.priority == "emergency")
    elif focus != "all":
        query = query.where(Order.status == focus)
    return query


def sort_columns(sort):
    if sort == "deadline":
        return [Order.deadline, Order.id], False
    if sort == "priority":
        rank = case(*[(Order.priority == priority, value) for priority, value in QUEUE_PRIORITIES.items()],
            else_=len(QUEUE_PRIORITIES))
        return [rank, Order.deadline, Order.id], False
    return [Order.created_at, Order.id], True


def after_cursor(query, columns, descending, last):
    comparisons = []
    for index, (column, value) in enumerate(zip(columns, last)):
        prior = [columns[previous] == last[previous] for previous in range(index)]
        comparisons.append(and_(*prior, column < value if descending else column > value))
    return query.where(or_(*comparisons))


def order_tuple(order, sort):
    if sort == "priority":
        return [QUEUE_PRIORITIES[order.priority], iso(aware(order.deadline).astimezone(timezone.utc)), order.id]
    timestamp = order.deadline if sort == "deadline" else order.created_at
    return [iso(aware(timestamp).astimezone(timezone.utc)), order.id]
