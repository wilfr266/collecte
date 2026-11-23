import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:terenza/core/network/offline_store.dart';

class _MemoryKeyStore implements OfflineKeyStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late Directory temporaryDirectory;
  late String databasePath;
  late _MemoryKeyStore keyStore;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'terenza-offline-',
    );
    databasePath = path.join(temporaryDirectory.path, 'offline.db');
    keyStore = _MemoryKeyStore();
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('outbox survives reopening and stays scoped to its owner', () async {
    final store = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    final operationId = await store.enqueue(
      ownerUserId: 'collector-a',
      operationType: 'collection_payment_request',
      resourceRef: 'obligation-a',
      idempotencyKey: 'stable-idempotency-key-a',
      payload: const {
        'assignment_id': 'assignment-a',
        'amount': 12000,
        'method': 'cash',
      },
    );
    await store.markSyncing(operationId);
    await store.close();

    final reopenedStore = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    final ownerQueue = await reopenedStore.queuedOperations(
      ownerUserId: 'collector-a',
    );
    final otherOwnerQueue = await reopenedStore.queuedOperations(
      ownerUserId: 'collector-b',
    );

    expect(ownerQueue, hasLength(1));
    expect(ownerQueue.single.idempotencyKey, 'stable-idempotency-key-a');
    expect(ownerQueue.single.payload['amount'], 12000);
    expect(ownerQueue.single.state, OutboxState.retryable);
    expect(otherOwnerQueue, isEmpty);
    await reopenedStore.close();
  });

  test('upgrading a v3 device keeps every queued operation', () async {
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE sync_outbox (
              id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, operation_type TEXT NOT NULL,
              resource_ref TEXT NOT NULL, created_at TEXT NOT NULL,
              state TEXT NOT NULL CHECK (state IN ('pending', 'syncing', 'retryable', 'needsAttention', 'synced')),
              attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT, technical_error TEXT,
              idempotency_key TEXT NOT NULL UNIQUE, payload_ciphertext BLOB NOT NULL,
              payload_nonce BLOB NOT NULL, payload_mac BLOB NOT NULL)
          ''');
          await db.execute(
            'CREATE INDEX sync_outbox_queue_idx ON sync_outbox(state, created_at)',
          );
          await db.execute('''
            CREATE TABLE offline_cache (category TEXT NOT NULL, record_id TEXT NOT NULL,
              organization_id TEXT NOT NULL, owner_user_id TEXT NOT NULL, fetched_at TEXT NOT NULL,
              payload_ciphertext BLOB NOT NULL, payload_nonce BLOB NOT NULL,
              payload_mac BLOB NOT NULL, PRIMARY KEY(category, record_id))
          ''');
          await db.execute(
            'CREATE TABLE sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
      ),
    );
    await legacy.insert('sync_outbox', {
      'id': 'legacy-operation',
      'owner_user_id': 'collector-a',
      'operation_type': 'collection_payment_request',
      'resource_ref': 'obligation-a',
      'created_at': '2026-11-01T08:00:00Z',
      'state': 'retryable',
      'attempts': 2,
      'idempotency_key': 'legacy-idempotency-key',
      'payload_ciphertext': Uint8List.fromList([1, 2, 3]),
      'payload_nonce': Uint8List.fromList([4, 5, 6]),
      'payload_mac': Uint8List.fromList([7, 8, 9]),
    });
    await legacy.close();

    final store = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    await store.close();

    final upgraded = await databaseFactoryFfi.openDatabase(databasePath);
    expect(await upgraded.getVersion(), 4);
    final rows = await upgraded.query('sync_outbox');
    expect(rows, hasLength(1));
    expect(rows.single['state'], 'retryable');
    expect(rows.single['attempts'], 2);
    expect(rows.single['idempotency_key'], 'legacy-idempotency-key');
    expect(rows.single['payload_ciphertext'], [1, 2, 3]);
    await upgraded.update('sync_outbox', {'state': 'dismissed'});
    await upgraded.close();
  });

  test(
    'a server-refused request can be dismissed, then corrected and resent',
    () async {
      final store = await OfflineStore.open(
        factory: databaseFactoryFfi,
        databasePath: databasePath,
        keyStore: keyStore,
      );
      Future<String> enqueue(String key) => store.enqueue(
        ownerUserId: 'collector-a',
        operationType: 'collection_payment_request',
        resourceRef: 'payment:establishment-a',
        idempotencyKey: key,
        payload: const {'amount': 5000, 'method': 'cash'},
      );
      final refusedId = await enqueue('refused-request-key-1');
      await store.markNeedsAttention(
        refusedId,
        technicalError: 'server_validation_conflict',
      );

      // Tant qu'elle n'est pas close, la demande bloquée empêche un doublon.
      await expectLater(
        enqueue('corrected-request-key'),
        throwsA(isA<OfflineOperationAlreadyPending>()),
      );
      // Ni un autre utilisateur ni une opération non refusée ne se ferment.
      expect(
        await store.dismissRejected(refusedId, ownerUserId: 'collector-b'),
        isFalse,
      );

      expect(
        await store.dismissRejected(refusedId, ownerUserId: 'collector-a'),
        isTrue,
      );
      final dismissed = await store.operationById(
        refusedId,
        ownerUserId: 'collector-a',
      );
      expect(dismissed?.state, OutboxState.dismissed);
      expect(dismissed?.payload, isEmpty);
      expect(await store.pendingCount(ownerUserId: 'collector-a'), 0);
      expect(await store.needsAttentionCount(ownerUserId: 'collector-a'), 0);

      final correctedId = await enqueue('corrected-request-key');
      expect(
        (await store.queuedOperations(ownerUserId: 'collector-a')).single.id,
        correctedId,
      );
      expect(
        await store.dismissRejected(correctedId, ownerUserId: 'collector-a'),
        isFalse,
      );
      await store.close();
    },
  );

  test('encrypted payload is not written as plaintext into SQLite', () async {
    final store = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    await store.enqueue(
      ownerUserId: 'collector-a',
      operationType: 'collection_payment_request',
      resourceRef: 'obligation-a',
      payload: const {'private_note': 'terrain confidentiel'},
    );
    await store.close();

    final database = await databaseFactoryFfi.openDatabase(databasePath);
    final rows = await database.query('sync_outbox');
    final ciphertext = rows.single['payload_ciphertext'] as List<int>;

    expect(
      String.fromCharCodes(ciphertext),
      isNot(contains('terrain confidentiel')),
    );
    await database.close();
  });

  test('duplicate idempotency keys are rejected locally', () async {
    final store = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    Future<String> enqueue() => store.enqueue(
      ownerUserId: 'collector-a',
      operationType: 'collection_payment_request',
      resourceRef: 'obligation-a',
      idempotencyKey: 'same-idempotency-key',
      payload: const {'amount': 5000},
    );

    await enqueue();
    await expectLater(enqueue(), throwsException);
    await store.close();
  });

  test(
    'a second unresolved operation for the same resource is rejected',
    () async {
      final store = await OfflineStore.open(
        factory: databaseFactoryFfi,
        databasePath: databasePath,
        keyStore: keyStore,
      );
      await store.enqueue(
        ownerUserId: 'collector-a',
        operationType: 'collection_visit',
        resourceRef: 'establishment-a',
        payload: const {'outcome': 'contacted'},
      );

      await expectLater(
        store.enqueue(
          ownerUserId: 'collector-a',
          operationType: 'collection_visit',
          resourceRef: 'establishment-a',
          payload: const {'outcome': 'contacted'},
        ),
        throwsA(isA<OfflineOperationAlreadyPending>()),
      );
      await store.close();
    },
  );

  test(
    'conflicts remain visible but are excluded from automatic retries',
    () async {
      final store = await OfflineStore.open(
        factory: databaseFactoryFfi,
        databasePath: databasePath,
        keyStore: keyStore,
      );
      final id = await store.enqueue(
        ownerUserId: 'collector-a',
        operationType: 'collection_payment_request',
        resourceRef: 'obligation-a',
        payload: const {'amount': 5000},
      );
      await store.markNeedsAttention(id, technicalError: 'permission_denied');

      expect(await store.queuedOperations(ownerUserId: 'collector-a'), isEmpty);
      expect(
        await store.operationsNeedingAttention(ownerUserId: 'collector-a'),
        hasLength(1),
      );
      await store.close();
    },
  );

  test('cache is encrypted, persistent and isolated by user', () async {
    final store = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    await store.cacheRecords(
      category: 'missions',
      organizationId: 'org-a',
      userId: 'collector-a',
      records: const [
        {'id': 'mission-a', 'title': 'Mission locale'},
      ],
    );
    await store.close();

    final reopenedStore = await OfflineStore.open(
      factory: databaseFactoryFfi,
      databasePath: databasePath,
      keyStore: keyStore,
    );
    final ownerRecords = await reopenedStore.cachedRecordsForUser(
      category: 'missions',
      userId: 'collector-a',
    );
    final otherOwnerRecords = await reopenedStore.cachedRecordsForUser(
      category: 'missions',
      userId: 'collector-b',
    );

    expect(ownerRecords.single['title'], 'Mission locale');
    expect(otherOwnerRecords, isEmpty);
    await reopenedStore.close();
  });
}
