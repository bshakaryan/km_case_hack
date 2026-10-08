import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/local_store_io.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _server = 'http://recovery-sqlite.test/api';

OutboxCommand _command(
  String id,
  String kind,
  int time, {
  int owner = 7,
  int? orderId,
  String? localRef = 'create-local',
  String? previous,
  int? version,
}) => OutboxCommand(
  commandId: id,
  kind: kind,
  createdAt: time,
  ownerId: owner,
  serverUrl: _server,
  orderId: orderId,
  localRef: localRef,
  previousCommandId: previous,
  expectedVersion: version,
  payload: const {'work_done': 'Сохранённый ремонт', 'materials': []},
  state: OutboxState.conflict,
  attempts: 5,
  lastError: 'Synthetic retained failure',
);

Future<({SqfliteLocalStore store, Directory folder, Database database})>
_fixture() async {
  final folder = await Directory.systemTemp.createTemp('naryad-recovery-');
  final store = SqfliteLocalStore(
    directoryPath: folder.path,
    dbFactory: databaseFactoryFfi,
  );
  await store.open();
  final database = await databaseFactoryFfi.openDatabase(
    '${folder.path}/local_store.db',
  );
  addTearDown(() async {
    await store.close();
    // Delete only this test's own freshly generated directory.
    if (folder.parent.absolute.path != Directory.systemTemp.absolute.path ||
        !folder.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('naryad-recovery-')) {
      throw StateError('Unexpected test cleanup path');
    }
    if (await folder.exists()) await folder.delete(recursive: true);
  });
  return (store: store, folder: folder, database: database);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'SQLite chain deletion rolls back rows, ID map and media together',
    () async {
      final fixture = await _fixture();
      final store = fixture.store;
      final mapping = localScopeKey(_server, 7, 'create-local');
      final foreignMapping = localScopeKey(_server, 8, 'create-local');
      final draftKey = localScopeKey(_server, 7, 'retained-draft');
      final bytes = Uint8List.fromList([1, 3, 5, 7]);
      final selected = [
        await store.enqueue(
          _command('create-a-0001', OutboxKind.createOrder, 1),
        ),
        await store.enqueue(
          _command(
            'photo-a-0002',
            OutboxKind.uploadPhoto,
            2,
            previous: 'create-a-0001',
          ),
          photoBytes: bytes,
        ),
        await store.enqueue(
          _command(
            'complete-a-0003',
            OutboxKind.complete,
            3,
            previous: 'photo-a-0002',
          ),
        ),
      ];
      final foreign = await store.enqueue(
        _command(
          'photo-b-0001',
          OutboxKind.uploadPhoto,
          4,
          owner: 8,
          orderId: 81,
          version: 2,
        ),
        photoBytes: Uint8List.fromList([2, 4]),
      );
      final other = await store.enqueue(
        _command(
          'other-a-0001',
          OutboxKind.transition,
          5,
          orderId: 99,
          localRef: null,
          version: 6,
        ),
      );
      await store.putServerId(mapping, 81);
      await store.putServerId(foreignMapping, 81);
      await store.putFormDraft(draftKey, const {'text': 'Не удалять'});
      final before = (await store.outbox()).map((c) => c.toJson()).toList();
      await fixture.database.execute('''
      CREATE TRIGGER reject_test_mapping_delete BEFORE DELETE ON id_map
      BEGIN SELECT RAISE(ABORT, 'synthetic_mapping_failure'); END
    ''');

      await expectLater(
        store.recoverOutbox(
          selected,
          serverIdKeys: [mapping],
          ensureCurrent: () {},
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await store.outbox()).map((c) => c.toJson()).toList(), before);
      expect(await store.serverId(mapping), 81);
      expect(await store.outboxPhoto('photo-a-0002'), bytes);
      expect(await store.getFormDraft(draftKey), {'text': 'Не удалять'});

      await fixture.database.execute('DROP TRIGGER reject_test_mapping_delete');
      final commit = await store.recoverOutbox(
        selected,
        serverIdKeys: [mapping],
        ensureCurrent: () {},
      );
      expect(commit.committed, true);
      expect(commit.cleanupWarning, isNull);
      expect(await File(selected[1].photoPath!).exists(), false);
      await store.close();
      await store.open();
      expect((await store.outbox()).map((c) => c.commandId), [
        foreign.commandId,
        other.commandId,
      ]);
      expect(await store.serverId(mapping), isNull);
      expect(await store.serverId(foreignMapping), 81);
      expect(await store.outboxPhoto(foreign.commandId), [2, 4]);
      expect(await store.getFormDraft(draftKey), {'text': 'Не удалять'});
    },
  );

  test(
    'SQLite stale/running recovery cannot remove retained commands',
    () async {
      final fixture = await _fixture();
      final store = fixture.store;
      final original = await store.enqueue(
        _command(
          'stale-a-0001',
          OutboxKind.complete,
          1,
          orderId: 81,
          localRef: null,
          version: 3,
        ),
      );
      final updated = original.copyWith(lastError: 'Newer saved result');
      await store.updateOutbox(updated);
      final stale = await store.recoverOutbox([original], ensureCurrent: () {});
      expect(stale.status, OutboxRecoveryCommitStatus.changed);
      expect((await store.outbox()).single.toJson(), updated.toJson());
      final running = updated.copyWith(state: OutboxState.running);
      await store.updateOutbox(running);
      final busy = await store.recoverOutbox([running], ensureCurrent: () {});
      expect(busy.status, OutboxRecoveryCommitStatus.busy);
      expect((await store.outbox()).single.toJson(), running.toJson());
    },
  );

  test(
    'SQLite cancelled scope rolls back and retry preserves exact basis',
    () async {
      final fixture = await _fixture();
      final store = fixture.store;
      final original = await store.enqueue(
        _command(
          'cancel-a-0001',
          OutboxKind.complete,
          1,
          orderId: 81,
          localRef: null,
          version: 3,
        ),
      );
      var checks = 0;
      await expectLater(
        store.recoverOutbox(
          [original],
          ensureCurrent: () {
            if (++checks >= 2) throw StateError('Synthetic session changed');
          },
        ),
        throwsStateError,
      );
      expect(checks, greaterThanOrEqualTo(2));
      expect((await store.outbox()).single.toJson(), original.toJson());
      final replacement = original.copyWith(
        state: OutboxState.pending,
        attempts: 0,
        lastError: null,
        responseStatus: null,
        response: null,
      );
      final commit = await store.recoverOutbox(
        [original],
        replacement: replacement,
        ensureCurrent: () {},
      );
      expect(commit.committed, true);
      final saved = (await store.outbox()).single;
      expect(saved.commandId, original.commandId);
      expect(saved.payload, original.payload);
      expect(saved.expectedVersion, 3);
      expect(saved.previousCommandId, original.previousCommandId);
      expect(saved.state, OutboxState.pending);
      expect(saved.attempts, 0);
    },
  );

  test(
    'SQLite committed cleanup never deletes an unrelated file path',
    () async {
      final fixture = await _fixture();
      final unrelated = File('${fixture.folder.path}/keep-other.photo');
      await unrelated.writeAsBytes([9, 9, 9], flush: true);
      final command = await fixture.store.enqueue(
        _command(
          'foreign-path-0001',
          OutboxKind.uploadPhoto,
          1,
          orderId: 81,
          localRef: null,
          version: 3,
        ).copyWith(photoPath: unrelated.path),
      );
      final result = await fixture.store.recoverOutbox([
        command,
      ], ensureCurrent: () {});
      expect(result.committed, true);
      expect(result.cleanupWarning, isNotNull);
      expect(await fixture.store.outbox(), isEmpty);
      expect(await unrelated.readAsBytes(), [9, 9, 9]);
    },
  );
}
