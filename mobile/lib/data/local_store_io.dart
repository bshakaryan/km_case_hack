import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'local_store.dart';
import 'models.dart';

class SqfliteLocalStore implements LocalStore {
  SqfliteLocalStore({this.directoryPath});

  final String? directoryPath;
  Database? _db;
  Directory? _root;

  static const _schemaVersion = 4;

  @override
  Future<void> open() async {
    if (_db != null) return;
    final path =
        directoryPath ??
        '${(await getApplicationDocumentsDirectory()).path}/naryad_local_store';
    final root = Directory(path);
    await root.create(recursive: true);
    _root = root;
    final db = await openDatabase(
      '${root.path}/local_store.db',
      version: _schemaVersion,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE outbox ADD COLUMN server_url TEXT');
          // The old schema cannot prove which server owned its commands.
          // Preserve commands/media for recovery, but never guess ownership.
          await db.update('outbox', {
            'state': OutboxState.conflict,
            'last_error': 'Старая команда без подтверждённого сервера и аккаунта изолирована.',
          }, where: 'server_url IS NULL OR owner_id IS NULL');
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE outbox ADD COLUMN expected_version INTEGER',
          );
          await db.execute(
            'ALTER TABLE outbox ADD COLUMN previous_command_id TEXT',
          );
          await db.update(
            'outbox',
            {
              'state': OutboxState.conflict,
              'response': jsonEncode({
                'code': 'local_order_precondition_unavailable',
              }),
              'last_error': 'Версия наряда для старой команды неизвестна. Текст и фото сохранены. Обновите наряд и создайте действие заново; удаление команды не отменяет уже сохранённое сервером действие.',
            },
            where: 'kind NOT IN (?, ?)',
            whereArgs: [OutboxKind.createOrder, OutboxKind.markRead],
          );
        }
        if (oldVersion < 4) {
          await _createDraftSchema(db);
        }
      },
    );
    _db = db;
    await resetRunningOutbox();
  }

  Future<void> _createSchema(Database db) async {
    await _createDraftSchema(db);
    await db.execute(
      'CREATE TABLE snapshot (key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE outbox (command_id TEXT PRIMARY KEY, kind TEXT NOT NULL, created_at INTEGER NOT NULL, owner_id INTEGER, server_url TEXT, order_id INTEGER, local_ref TEXT, expected_version INTEGER, previous_command_id TEXT, payload TEXT NOT NULL, photo_path TEXT, photo_filename TEXT, photo_kind TEXT, attempts INTEGER NOT NULL, state TEXT NOT NULL, response_status INTEGER, response TEXT, last_error TEXT)',
    );
    await db.execute(
      'CREATE INDEX ix_outbox_state ON outbox (state, created_at)',
    );
    await db.execute(
      'CREATE TABLE id_map (local_ref TEXT PRIMARY KEY, server_id INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE photo_cache (url TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, last_used_at INTEGER NOT NULL)',
    );
  }

  Future<void> _createDraftSchema(Database db) => db.execute(
    'CREATE TABLE form_drafts (key TEXT PRIMARY KEY, payload TEXT NOT NULL)',
  );

  @override
  Future<void> putFormDraft(String key, Json data) async {
    await _database.insert('form_drafts', {
      'key': key,
      'payload': jsonEncode(data),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<Json?> getFormDraft(String key) async {
    final rows = await _database.query(
      'form_drafts',
      columns: ['payload'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['payload'] as String) as Json;
  }

  @override
  Future<void> removeFormDraft(String key) async {
    await _database.delete('form_drafts', where: 'key = ?', whereArgs: [key]);
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('Local store is not open');
    }
    return db;
  }

  Directory get _directory {
    final root = _root;
    if (root == null) {
      throw StateError('Local store is not open');
    }
    return root;
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  }) async {
    await _database.insert('snapshot', {
      'key': key,
      'payload': jsonEncode(data),
      'updated_at': updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<SnapshotEntry?> getSnapshot(String key) async {
    final rows = await _database.query(
      'snapshot',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SnapshotEntry(
      jsonDecode(row['payload'] as String),
      DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as num).toInt()),
    );
  }

  @override
  Future<void> clearSnapshots({String? prefix}) async {
    if (prefix == null) {
      await _database.delete('snapshot');
      return;
    }
    final rows = await _database.query('snapshot', columns: ['key']);
    final batch = _database.batch();
    for (final row in rows) {
      if ((row['key'] as String).startsWith(prefix)) {
        batch.delete('snapshot', where: 'key = ?', whereArgs: [row['key']]);
      }
    }
    await batch.commit(noResult: true);
  }

  Map<String, Object?> _outboxRow(OutboxCommand command) => <String, Object?>{
    'command_id': command.commandId,
    'kind': command.kind,
    'created_at': command.createdAt,
    'owner_id': command.ownerId,
    'server_url': command.serverUrl,
    'order_id': command.orderId,
    'local_ref': command.localRef,
    'expected_version': command.expectedVersion,
    'previous_command_id': command.previousCommandId,
    'payload': jsonEncode(command.payload),
    'photo_path': command.photoPath,
    'photo_filename': command.photoFilename,
    'photo_kind': command.photoKind,
    'attempts': command.attempts,
    'state': command.state,
    'response_status': command.responseStatus,
    'response': command.response == null ? null : jsonEncode(command.response),
    'last_error': command.lastError,
  };

  OutboxCommand _commandFromRow(Map<String, Object?> row) =>
      OutboxCommand.fromJson({
        'command_id': row['command_id'],
        'kind': row['kind'],
        'created_at': row['created_at'],
        'owner_id': row['owner_id'],
        'server_url': row['server_url'],
        'order_id': row['order_id'],
        'local_ref': row['local_ref'],
        'expected_version': row['expected_version'],
        'previous_command_id': row['previous_command_id'],
        'payload': jsonDecode(row['payload'] as String),
        'photo_path': row['photo_path'],
        'photo_filename': row['photo_filename'],
        'photo_kind': row['photo_kind'],
        'attempts': row['attempts'],
        'state': row['state'],
        'response_status': row['response_status'],
        'response': row['response'] == null
            ? null
            : jsonDecode(row['response'] as String),
        'last_error': row['last_error'],
      });

  @override
  Future<OutboxCommand> enqueue(
    OutboxCommand command, {
    Uint8List? photoBytes,
  }) async {
    var stored = command;
    if (photoBytes != null) {
      final folder = Directory('${_directory.path}/outbox_photos');
      await folder.create(recursive: true);
      final path = '${folder.path}/${command.commandId}.photo';
      await File(path).writeAsBytes(photoBytes, flush: true);
      stored = command.copyWith(photoPath: path);
    }
    await _database.insert('outbox', _outboxRow(stored));
    return stored;
  }

  @override
  Future<List<OutboxCommand>> outbox() async {
    final rows = await _database.query(
      'outbox',
      orderBy: 'created_at, command_id',
    );
    return rows.map(_commandFromRow).toList();
  }

  @override
  Future<void> updateOutbox(OutboxCommand command) async {
    await _database.update(
      'outbox',
      _outboxRow(command),
      where: 'command_id = ?',
      whereArgs: [command.commandId],
    );
  }

  @override
  Future<void> removeOutbox(String commandId) async {
    final rows = await _database.query(
      'outbox',
      columns: ['photo_path'],
      where: 'command_id = ?',
      whereArgs: [commandId],
    );
    await _database.delete(
      'outbox',
      where: 'command_id = ?',
      whereArgs: [commandId],
    );
    final path = rows.isEmpty ? null : rows.first['photo_path'] as String?;
    final file = path != null
        ? File(path)
        : File('${_directory.path}/outbox_photos/$commandId.photo');
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> resetRunningOutbox() async {
    await _database.update('outbox', {
      'state': OutboxState.conflict,
      'last_error':
          'Старая команда без подтверждённого сервера и аккаунта изолирована.',
    }, where: 'server_url IS NULL OR owner_id IS NULL');
    final commands = await outbox();
    for (final command in commands) {
      if (command.serverUrl == null ||
          command.ownerId == null ||
          command.hasOrderPrecondition) {
        continue;
      }
      await updateOutbox(
        command.copyWith(
          state: OutboxState.conflict,
          response: {'code': 'local_order_precondition_unavailable'},
          lastError: 'Версия наряда для этого действия неизвестна. Текст и фото сохранены. Обновите наряд и создайте действие заново; удаление команды не отменяет уже сохранённое сервером действие.',
        ),
      );
    }
    await _database.update(
      'outbox',
      {'state': OutboxState.pending},
      where: 'state = ?',
      whereArgs: [OutboxState.running],
    );
  }

  @override
  Future<Uint8List?> outboxPhoto(String commandId) async {
    final rows = await _database.query(
      'outbox',
      columns: ['photo_path'],
      where: 'command_id = ?',
      whereArgs: [commandId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final path = rows.first['photo_path'] as String?;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> putServerId(String localRef, int serverId) async {
    await _database.insert('id_map', {
      'local_ref': localRef,
      'server_id': serverId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<int?> serverId(String localRef) async {
    final rows = await _database.query(
      'id_map',
      columns: ['server_id'],
      where: 'local_ref = ?',
      whereArgs: [localRef],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['server_id'] as num).toInt();
  }

  @override
  Future<void> removeServerId(String localRef) async {
    await _database.delete(
      'id_map',
      where: 'local_ref = ?',
      whereArgs: [localRef],
    );
  }

  File _photoFile(String url) => File(
    '${_directory.path}/photo_cache/${base64Url.encode(utf8.encode(url))}.img',
  );

  @override
  Future<void> putPhoto(String url, Uint8List bytes) async {
    final folder = Directory('${_directory.path}/photo_cache');
    await folder.create(recursive: true);
    final file = _photoFile(url);
    await file.writeAsBytes(bytes, flush: true);
    await _database.insert('photo_cache', {
      'url': url,
      'path': file.path,
      'size': bytes.length,
      'last_used_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _evictPhotos();
  }

  Future<void> _evictPhotos() async {
    final rows = await _database.query(
      'photo_cache',
      orderBy: 'last_used_at, url',
    );
    var total = 0;
    for (final row in rows) {
      total += (row['size'] as num).toInt();
    }
    for (final row in rows) {
      if (total <= maxPhotoCacheBytes) break;
      total -= (row['size'] as num).toInt();
      await File(row['path'] as String)
          .delete()
          .catchError((Object _) => File(row['path'] as String));
      await _database.delete(
        'photo_cache',
        where: 'url = ?',
        whereArgs: [row['url']],
      );
    }
  }

  @override
  Future<Uint8List?> getPhoto(String url) async {
    final rows = await _database.query(
      'photo_cache',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final file = File(rows.first['path'] as String);
    if (!await file.exists()) {
      await _database.delete('photo_cache', where: 'url = ?', whereArgs: [url]);
      return null;
    }
    await _database.update(
      'photo_cache',
      {'last_used_at': DateTime.now().millisecondsSinceEpoch},
      where: 'url = ?',
      whereArgs: [url],
    );
    return file.readAsBytes();
  }

  @override
  Future<void> clearPhotos({String? prefix}) async {
    final rows = await _database.query('photo_cache');
    for (final row in rows) {
      if (prefix != null && !(row['url'] as String).startsWith(prefix)) {
        continue;
      }
      await File(row['path'] as String)
          .delete()
          .catchError((Object _) => File(row['path'] as String));
      await _database.delete(
        'photo_cache',
        where: 'url = ?',
        whereArgs: [row['url']],
      );
    }
  }

  @override
  Future<int> photoCacheBytes() async {
    final rows = await _database.query('photo_cache', columns: ['size']);
    var total = 0;
    for (final row in rows) {
      total += (row['size'] as num).toInt();
    }
    return total;
  }
}
