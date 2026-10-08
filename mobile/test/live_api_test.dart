// Opt in only against a disposable, seeded demo server:
// flutter test test/live_api_test.dart --dart-define=LIVE_API_URL=http://127.0.0.1:8000
// Creates a synthetic order and photos; does not edit existing seeded orders.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/models.dart';


const liveUrl = String.fromEnvironment('LIVE_API_URL');

void main() {
  test(
    'real Dart API: two roles, photos, manual acceptance and permissions',
    () async {
      final master = NaryadApi(liveUrl);
      final worker = NaryadApi(liveUrl);
      final foreignWorker = NaryadApi(liveUrl);
      int? createdId;
      try {
        await master.login('master', '1234');
        await worker.login('worker2', '1234');
        await foreignWorker.login('worker', '1234');
        final user = await worker.me();
        expect(user.id, 6);
        expect(user.isWorker, isTrue);
        expect((await master.me()).isMaster, isTrue);
        final reference = await master.reference();
        final equipment = (reference['equipment'] as List).first as Json;
        final material = (reference['materials'] as List).first as Json;
        final fault = (reference['fault_codes'] as List).first as Json;
        final title =
            'Flutter API test ${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final created = await master.createOrder({
          'title': title,
          'description':
              'Синтетическая проверка совместимости мобильного клиента с API.',
          'work_type': 'unplanned',
          'area_id': equipment['area_id'],
          'equipment_id': equipment['id'],
          'assignee_id': user.id,
          'priority': 'emergency',
          'deadline': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 2))
              .toIso8601String(),
          'normal_hours': 1.5,
          'comment': 'Автоматический тест; оборудование фактически не ремонтировалось.',
        });
        createdId = created.id;
        expect(created.status, 'issued');
        expect(created.normalHours, 1.5);
        expect((await worker.order(created.id)).title, title);
        expect(
          (await worker.orders()).any((o) => o['id'] == created.id),
          isTrue,
        );

        await expectLater(
          foreignWorker.order(created.id),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'foreign access',
              403,
            ),
          ),
        );
        expect(
          (await worker.transition(created.id, 'accept')).status,
          'accepted',
        );
        expect(
          (await worker.transition(created.id, 'start')).status,
          'in_progress',
        );
        final completion = <String, dynamic>{
          'work_done':
              'Тест: заменён узел, выполнен контрольный запуск оборудования.',
          'fault_code_id': fault['id'],
          'materials': [
            {'material_id': material['id'], 'quantity': 2.0},
          ],
          'comment': 'Синтетические данные для проверки протокола.',
        };
        await expectLater(
          worker.complete(created.id, completion),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'missing required photo', 422)
                .having(
                  (e) => e.message,
                  'readable API error',
                  contains('фото'),
                )
                .having(
                  (e) => e.requestMayHaveSucceeded,
                  'known refusal',
                  false,
                ),
          ),
        );
        final before = img.Image(width: 40, height: 30);
        img.fill(before, color: img.ColorRgb8(150, 70, 30));
        final after = img.Image(width: 40, height: 30);
        img.fill(after, color: img.ColorRgb8(30, 150, 70));
        await worker.uploadPhoto(
          created.id,
          Uint8List.fromList(img.encodePng(before)),
          'synthetic-before.png',
          'before',
        );
        await worker.uploadPhoto(
          created.id,
          Uint8List.fromList(img.encodePng(after)),
          'synthetic-after.png',
          'after',
        );
        final withPhotos = await worker.order(created.id);
        final photos = (withPhotos.data['photos'] as List).cast<Json>();
        expect(photos.length, 2);
        final jpeg = await worker.photo(photos.first['id'] as int);
        expect(jpeg.take(2).toList(), [0xff, 0xd8]);
        expect(img.decodeImage(jpeg), isNotNull);
        await expectLater(
          foreignWorker.photo(photos.first['id'] as int),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'foreign photo access',
              403,
            ),
          ),
        );

        final acknowledged = await worker.complete(created.id, completion);
        expect(acknowledged.status, 'completed');
        final submitted = await worker.order(created.id);
        expect(submitted.status, 'completed');
        expect(submitted.data.containsKey('ai_review'), isFalse);
        final usages =
            ((submitted.data['completion'] as Json)['materials'] as List)
                .cast<Json>();
        expect(usages.single['quantity'], 2.0);
        await expectLater(
          worker.transition(created.id, 'close', score: 4),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'worker cannot accept own result',
              403,
            ),
          ),
        );
        final closed = await master.transition(created.id, 'close', score: 4);
        expect(closed.status, 'closed');
        expect(closed.score, 4.0);
        final detail = await master.order(created.id);
        final actions = (detail.data['events'] as List)
            .cast<Json>()
            .map((e) => e['action'])
            .toList();
        expect(
          actions,
          containsAllInOrder([
            'issue',
            'accept',
            'start',
            'photo',
            'photo',
            'complete',
            'close',
          ]),
        );
        final notification = (await worker.notifications()).firstWhere(
          (n) => n['order_id'] == created.id,
        );
        await worker.markRead(notification['id'] as int);
        expect(
          (await worker.notifications()).firstWhere(
            (n) => n['id'] == notification['id'],
          )['read'],
          isTrue,
        );
        expect((await master.dashboard())['total'], greaterThan(0));
        expect((await master.analytics())['summary'], isA<Json>());
        expect(await master.employees(), isNotEmpty);
      } finally {
        if (createdId != null && master.token != null) {
          try {
            final last = await master.order(createdId);
            if (!['closed', 'cancelled'].contains(last.status)) {
              await master.transition(
                createdId,
                'cancel',
                reason:
                    'Очистка незавершённого синтетического Flutter API теста.',
              );
            }
          } on ApiException {
            // An unavailable server cannot be cleaned up; never retry a blind write.
          }
        }
        for (final api in [master, worker, foreignWorker]) {
          try {
            if (api.token != null) await api.logout();
          } on ApiException {
            // The disposable server will expire any session that could not be revoked.
          } finally {
            api.close();
          }
        }
      }
    },
    skip: liveUrl.isEmpty
        ? 'Set LIVE_API_URL for an isolated seeded demo server.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
