import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';

enum OutboxState { pending, syncing, retryable, needsAttention, synced }

class OfflineOperationAlreadyPending implements Exception {
  const OfflineOperationAlreadyPending();
}

abstract interface class OfflineKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureOfflineKeyStore implements OfflineKeyStore {
  const SecureOfflineKeyStore(this.storage);

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
}

class OutboxOperation {
  const OutboxOperation({
    required this.id,
    required this.ownerUserId,
    required this.operationType,
    required this.resourceRef,
    required this.createdAt,
    required this.state,
    required this.attempts,
    required this.technicalError,
    required this.idempotencyKey,
    required this.payload,
  });

  final String id;
  final String ownerUserId;
  final String operationType;
  final String resourceRef;
  final DateTime createdAt;
  final OutboxState state;
  final int attempts;
  final String? technicalError;
  final String idempotencyKey;
  final Map<String, dynamic> payload;
}

class OfflineStore {
  OfflineStore._(this._database, {required this.keyStore});

  static const _uuid = Uuid();
  static const _encryptionKeyName = 'terenza.offline.aes256.key';
  static final _algorithm = AesGcm.with256bits();

  final sqflite.Database _database;
  final OfflineKeyStore keyStore;

  static Future<OfflineStore> open({
    OfflineKeyStore? keyStore,
    sqflite.DatabaseFactory? factory,
    String? databasePath,
  }) async {
    final selectedFactory = factory ?? sqflite.databaseFactory;
    final resolvedPath =
        databasePath ??
        path.join(await getDatabasesPath(), 'terenza_offline.db');
    final database = await selectedFactory.openDatabase(
      resolvedPath,
      options: sqflite.OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE sync_outbox (
              id TEXT PRIMARY KEY,
              owner_user_id TEXT NOT NULL,
              operation_type TEXT NOT NULL,
              resource_ref TEXT NOT NULL,
              created_at TEXT NOT NULL,
              state TEXT NOT NULL CHECK (state IN ('pending', 'syncing', 'retryable', 'needsAttention', 'synced')),
              attempts INTEGER NOT NULL DEFAULT 0,
              next_attempt_at TEXT,
              technical_error TEXT,
              idempotency_key TEXT NOT NULL UNIQUE,
              payload_ciphertext BLOB NOT NULL,
              payload_nonce BLOB NOT NULL,
              payload_mac BLOB NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX sync_outbox_queue_idx ON sync_outbox(state, created_at)',
          );
          await db.execute('''
            CREATE TABLE offline_cache (
              category TEXT NOT NULL,
              record_id TEXT NOT NULL,
              organization_id TEXT NOT NULL,
              owner_user_id TEXT NOT NULL,
              fetched_at TEXT NOT NULL,
              payload_ciphertext BLOB NOT NULL,
              payload_nonce BLOB NOT NULL,
              payload_mac BLOB NOT NULL,
              PRIMARY KEY(category, record_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE sync_metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE sync_outbox ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              "ALTER TABLE offline_cache ADD COLUMN owner_user_id TEXT NOT NULL DEFAULT ''",
            );
            await db.delete('offline_cache');
            await db.update('sync_outbox', {
              'state': OutboxState.needsAttention.name,
              'technical_error': 'owner_requires_manual_review',
            });
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE sync_outbox ADD COLUMN next_attempt_at TEXT',
            );
          }
        },
        onOpen: (db) async {
          await db.update(
            'sync_outbox',
            {
              'state': OutboxState.retryable.name,
              'technical_error': 'previous_process_interrupted',
            },
            where: 'state = ?',
            whereArgs: [OutboxState.syncing.name],
          );
        },
      ),
    );
    final store = OfflineStore._(
      database,
      keyStore: keyStore ?? const SecureOfflineKeyStore(FlutterSecureStorage()),
    );
    await store._encryptionKey();
    return store;
  }

  Future<String> enqueue({
    required String ownerUserId,
    required String operationType,
    required String resourceRef,
    required Map<String, dynamic> payload,
    String? idempotencyKey,
  }) async {
    final id = _uuid.v4();
    final key = idempotencyKey ?? _uuid.v4();
    final encrypted = await _encrypt(jsonEncode(payload));
    await _database.transaction((transaction) async {
      final unresolved = await transaction.query(
        'sync_outbox',
        columns: ['id'],
        where:
            'owner_user_id = ? AND operation_type = ? AND resource_ref = ? AND state IN (?, ?, ?, ?)',
        whereArgs: [
          ownerUserId,
          operationType,
          resourceRef,
          OutboxState.pending.name,
          OutboxState.syncing.name,
          OutboxState.retryable.name,
          OutboxState.needsAttention.name,
        ],
        limit: 1,
      );
      if (unresolved.isNotEmpty) throw const OfflineOperationAlreadyPending();

      await transaction.insert('sync_outbox', {
        'id': id,
        'owner_user_id': ownerUserId,
        'operation_type': operationType,
        'resource_ref': resourceRef,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'state': OutboxState.pending.name,
        'attempts': 0,
        'idempotency_key': key,
        ...encrypted,
      });
    });
    return id;
  }

  Future<bool> hasUnresolvedOperation({
    required String ownerUserId,
    required String operationType,
    required String resourceRef,
  }) async {
    final rows = await _database.query(
      'sync_outbox',
      columns: ['id'],
      where:
          'owner_user_id = ? AND operation_type = ? AND resource_ref = ? AND state IN (?, ?, ?, ?)',
      whereArgs: [
        ownerUserId,
        operationType,
        resourceRef,
        OutboxState.pending.name,
        OutboxState.syncing.name,
        OutboxState.retryable.name,
        OutboxState.needsAttention.name,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<OutboxOperation>> queuedOperations({
    required String ownerUserId,
    bool forceRetry = false,
    int limit = 50,
  }) async {
    final rows = await _database.query(
      'sync_outbox',
      where: forceRetry
          ? 'owner_user_id = ? AND state IN (?, ?, ?)'
          : '''
              owner_user_id = ? AND (
                state IN (?, ?) OR
                (state = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
              )
            ''',
      whereArgs: forceRetry
          ? [
              ownerUserId,
              OutboxState.pending.name,
              OutboxState.syncing.name,
              OutboxState.retryable.name,
            ]
          : [
              ownerUserId,
              OutboxState.pending.name,
              OutboxState.syncing.name,
              OutboxState.retryable.name,
              DateTime.now().toUtc().toIso8601String(),
            ],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    final operations = <OutboxOperation>[];
    for (final row in rows) {
      final payload = await _decrypt(row);
      operations.add(
        OutboxOperation(
          id: row['id'] as String,
          ownerUserId: row['owner_user_id'] as String,
          operationType: row['operation_type'] as String,
          resourceRef: row['resource_ref'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
          state: OutboxState.values.byName(row['state'] as String),
          attempts: row['attempts'] as int,
          technicalError: row['technical_error'] as String?,
          idempotencyKey: row['idempotency_key'] as String,
          payload: payload,
        ),
      );
    }
    return operations;
  }

  Future<List<OutboxOperation>> operationsNeedingAttention({
    required String ownerUserId,
  }) async {
    final rows = await _database.query(
      'sync_outbox',
      where: 'owner_user_id = ? AND state = ?',
      whereArgs: [ownerUserId, OutboxState.needsAttention.name],
      orderBy: 'created_at ASC',
      limit: 100,
    );
    return [
      for (final row in rows)
        OutboxOperation(
          id: row['id'] as String,
          ownerUserId: row['owner_user_id'] as String,
          operationType: row['operation_type'] as String,
          resourceRef: row['resource_ref'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
          state: OutboxState.needsAttention,
          attempts: row['attempts'] as int,
          technicalError: row['technical_error'] as String?,
          idempotencyKey: row['idempotency_key'] as String,
          payload: await _decrypt(row),
        ),
    ];
  }

  Future<int> pendingCount({required String ownerUserId}) async =>
      Sqflite.firstIntValue(
        await _database.rawQuery(
          "SELECT COUNT(*) FROM sync_outbox WHERE owner_user_id = ? AND state IN ('pending', 'syncing', 'retryable', 'needsAttention')",
          [ownerUserId],
        ),
      ) ??
      0;

  Future<void> markSyncing(String id) async {
    await _database.rawUpdate(
      'UPDATE sync_outbox SET state = ?, attempts = attempts + 1, technical_error = NULL, next_attempt_at = NULL WHERE id = ?',
      [OutboxState.syncing.name, id],
    );
  }

  Future<void> markRetryable(
    String id, {
    required String technicalError,
  }) async {
    final rows = await _database.query(
      'sync_outbox',
      columns: ['attempts'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final attempts = rows.isEmpty ? 1 : rows.first['attempts'] as int;
    final delaySeconds = min(3600, 15 * pow(2, max(0, attempts - 1)).toInt());
    await _database.update(
      'sync_outbox',
      {
        'state': OutboxState.retryable.name,
        'technical_error': technicalError,
        'next_attempt_at': DateTime.now()
            .toUtc()
            .add(Duration(seconds: delaySeconds))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markNeedsAttention(
    String id, {
    required String technicalError,
  }) async {
    await _updateState(id, OutboxState.needsAttention, technicalError);
  }

  Future<void> markSynced(String id, {String? serverReference}) async {
    final clearedPayload = await _encrypt('{}');
    await _database.update(
      'sync_outbox',
      {
        'state': OutboxState.synced.name,
        'technical_error': null,
        'next_attempt_at': null,
        'resource_ref': ?serverReference,
        ...clearedPayload,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await setMetadata(
      'last_successful_sync',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _updateState(String id, OutboxState state, String? error) async {
    await _database.update(
      'sync_outbox',
      {'state': state.name, 'technical_error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> cacheRecords({
    required String category,
    required String organizationId,
    required String userId,
    required List<Map<String, dynamic>> records,
  }) async {
    await _database.transaction((transaction) async {
      await transaction.delete(
        'offline_cache',
        where: 'category = ? AND organization_id = ? AND owner_user_id = ?',
        whereArgs: [category, organizationId, userId],
      );
      for (final record in records) {
        final recordId = record['id'] as String?;
        if (recordId == null) continue;
        final fetchedAt = DateTime.now().toUtc().toIso8601String();
        final encrypted = await _encrypt(
          jsonEncode({...record, '_cached_at': fetchedAt}),
        );
        await transaction.insert('offline_cache', {
          'category': category,
          'record_id': recordId,
          'organization_id': organizationId,
          'owner_user_id': userId,
          'fetched_at': fetchedAt,
          ...encrypted,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      }
    });
  }

  static const _cacheMaxAge = Duration(days: 7);

  Future<List<Map<String, dynamic>>> cachedRecords({
    required String category,
    required String organizationId,
    required String userId,
  }) async {
    final rows = await _database.query(
      'offline_cache',
      where: 'category = ? AND organization_id = ? AND owner_user_id = ?',
      whereArgs: [category, organizationId, userId],
      orderBy: 'fetched_at DESC',
      limit: 500,
    );
    if (rows.isEmpty || !_isFresh(rows.first['fetched_at'] as String))
      return [];
    return [for (final row in rows) await _decrypt(row)];
  }

  Future<List<Map<String, dynamic>>> cachedRecordsForUser({
    required String category,
    required String userId,
  }) async {
    final rows = await _database.query(
      'offline_cache',
      where: 'category = ? AND owner_user_id = ?',
      whereArgs: [category, userId],
      orderBy: 'fetched_at DESC',
    );
    if (rows.isEmpty || !_isFresh(rows.first['fetched_at'] as String))
      return [];
    return [for (final row in rows) await _decrypt(row)];
  }

  bool _isFresh(String fetchedAt) =>
      DateTime.now().toUtc().difference(DateTime.parse(fetchedAt)) <=
      _cacheMaxAge;

  Future<void> clearUserCache(String userId) async {
    await _database.delete(
      'offline_cache',
      where: 'owner_user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<OutboxOperation?> operationById(
    String id, {
    required String ownerUserId,
  }) async {
    final rows = await _database.query(
      'sync_outbox',
      where: 'id = ? AND owner_user_id = ?',
      whereArgs: [id, ownerUserId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return OutboxOperation(
      id: row['id'] as String,
      ownerUserId: row['owner_user_id'] as String,
      operationType: row['operation_type'] as String,
      resourceRef: row['resource_ref'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      state: OutboxState.values.byName(row['state'] as String),
      attempts: row['attempts'] as int,
      technicalError: row['technical_error'] as String?,
      idempotencyKey: row['idempotency_key'] as String,
      payload: await _decrypt(row),
    );
  }

  Future<void> setMetadata(String key, String value) async {
    await _database.insert('sync_metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getMetadata(String key) async {
    final rows = await _database.query(
      'sync_metadata',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<int> needsAttentionCount({required String ownerUserId}) async =>
      Sqflite.firstIntValue(
        await _database.rawQuery(
          'SELECT COUNT(*) FROM sync_outbox WHERE state = ? AND owner_user_id = ?',
          [OutboxState.needsAttention.name, ownerUserId],
        ),
      ) ??
      0;

  Future<void> close() => _database.close();

  Future<SecretKey> _encryptionKey() async {
    final encoded = await keyStore.read(_encryptionKeyName);
    if (encoded != null) return SecretKey(base64Decode(encoded));
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await keyStore.write(_encryptionKeyName, base64Encode(bytes));
    return SecretKey(bytes);
  }

  Future<Map<String, Object>> _encrypt(String value) async {
    final random = Random.secure();
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final box = await _algorithm.encrypt(
      utf8.encode(value),
      secretKey: await _encryptionKey(),
      nonce: nonce,
    );
    return {
      'payload_ciphertext': Uint8List.fromList(box.cipherText),
      'payload_nonce': Uint8List.fromList(box.nonce),
      'payload_mac': Uint8List.fromList(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> _decrypt(Map<String, Object?> row) async {
    final box = SecretBox(
      _asBytes(row['payload_ciphertext']),
      nonce: _asBytes(row['payload_nonce']),
      mac: Mac(_asBytes(row['payload_mac'])),
    );
    final clearText = await _algorithm.decrypt(
      box,
      secretKey: await _encryptionKey(),
    );
    return jsonDecode(utf8.decode(clearText)) as Map<String, dynamic>;
  }

  List<int> _asBytes(Object? value) =>
      value is Uint8List ? value : List<int>.from(value! as List);
}
