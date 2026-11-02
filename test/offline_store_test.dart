import 'dart:io';

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
