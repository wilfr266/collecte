import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_client_provider.dart';
import 'offline_store.dart';

enum SyncStatus {
  connected,
  unstable,
  offline,
  syncing,
  completed,
  failed,
  needsAttention,
}

/// Résultat de la vérification serveur préalable à chaque synchronisation.
enum _SyncScope {
  /// Collecteur actif : profil, missions et établissements mis en cache.
  collector,

  /// Compte actif sans rôle collecteur (client, administrateur) : données
  /// lues en ligne uniquement, aucun cache local.
  onlineOnly,

  /// Profil absent, inactif ou sans rôle : rien n'est synchronisé.
  denied,
}

class OfflineSyncSnapshot {
  const OfflineSyncSnapshot({
    required this.status,
    required this.pendingOperations,
    required this.operationsNeedingAttention,
    required this.lastSuccessfulSync,
  });

  final SyncStatus status;
  final int pendingOperations;
  final int operationsNeedingAttention;
  final DateTime? lastSuccessfulSync;
}

class OfflineSyncManager extends ChangeNotifier with WidgetsBindingObserver {
  OfflineSyncManager({required this.store, required this.client});

  static const _maxAttempts = 8;

  final OfflineStore store;
  final SupabaseClient? client;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<AuthState>? _authSubscription;
  String? _activeUserId;
  SyncStatus _status = SyncStatus.offline;
  bool _networkAvailable = false;
  bool _isSyncing = false;
  int _pendingOperations = 0;
  int _operationsNeedingAttention = 0;
  int _lastAttemptFailures = 0;
  DateTime? _lastSuccessfulSync;
  final StreamController<OfflineSyncSnapshot> _updates =
      StreamController.broadcast();

  SyncStatus get status => _status;
  int get pendingOperations => _pendingOperations;
  int get operationsNeedingAttention => _operationsNeedingAttention;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;

  OfflineSyncSnapshot get snapshot => OfflineSyncSnapshot(
    status: _status,
    pendingOperations: _pendingOperations,
    operationsNeedingAttention: _operationsNeedingAttention,
    lastSuccessfulSync: _lastSuccessfulSync,
  );

  Stream<OfflineSyncSnapshot> get snapshots async* {
    yield snapshot;
    yield* _updates.stream;
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _activeUserId = client?.auth.currentUser?.id;
    _authSubscription = client?.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut) {
        final previousUserId = _activeUserId;
        _activeUserId = null;
        if (previousUserId != null)
          unawaited(store.clearUserCache(previousUserId));
        unawaited(_refreshCounts());
        _notify();
      } else {
        _activeUserId = client?.auth.currentUser?.id;
        if (_networkAvailable) unawaited(syncNow());
      }
    });
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _handleConnectivity,
      onError: (_) {
        _status = SyncStatus.unstable;
        _notify();
      },
    );
    await _loadMetadata();
    try {
      _handleConnectivity(await Connectivity().checkConnectivity());
    } catch (_) {
      _status = SyncStatus.unstable;
      _notify();
    }
    await _refreshCounts();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _networkAvailable) {
      unawaited(syncNow());
    }
  }

  void _handleConnectivity(List<ConnectivityResult> results) {
    final available = results.any(
      (result) => result != ConnectivityResult.none,
    );
    _networkAvailable = available;
    if (!available) {
      _status = SyncStatus.offline;
    } else if (!_isSyncing) {
      _status = _lastAttemptFailures > 0
          ? SyncStatus.unstable
          : SyncStatus.connected;
      unawaited(syncNow());
    }
    _notify();
  }

  Future<void> syncNow({bool forceRetry = false}) async {
    final userId = client?.auth.currentUser?.id;
    if (_isSyncing || !_networkAvailable || client == null || userId == null) {
      await _refreshCounts();
      return;
    }
    _isSyncing = true;
    _status = SyncStatus.syncing;
    _notify();
    var failed = false;
    var serverFailure = false;
    try {
      final scope = await _cacheAuthorizedRecords();
      if (scope == _SyncScope.denied) {
        await _refreshCounts();
        _status = SyncStatus.needsAttention;
        return;
      }
      await store.setMetadata(
        'last_successful_sync',
        DateTime.now().toUtc().toIso8601String(),
      );
      final operations = await store.queuedOperations(
        ownerUserId: userId,
        forceRetry: forceRetry,
      );
      for (final operation in operations) {
        if (operation.attempts >= _maxAttempts) {
          await store.markNeedsAttention(
            operation.id,
            technicalError: 'retry_limit_reached',
          );
          continue;
        }
        await store.markSyncing(operation.id);
        try {
          final serverReference = await _submitOperation(operation);
          await store.markSynced(
            operation.id,
            serverReference: serverReference,
          );
        } on PostgrestException catch (error) {
          failed = true;
          _lastAttemptFailures++;
          final conflict =
              error.code == '23505' ||
              error.code == '42501' ||
              error.code == '22023';
          if (conflict) {
            await store.markNeedsAttention(
              operation.id,
              technicalError: _safeErrorCode(error.code),
            );
          } else {
            serverFailure = true;
            await store.markRetryable(
              operation.id,
              technicalError: _safeErrorCode(error.code),
            );
          }
        } catch (_) {
          failed = true;
          _lastAttemptFailures++;
          await store.markRetryable(
            operation.id,
            technicalError: 'network_or_server_unavailable',
          );
          break;
        }
      }
      await _refreshCounts();
      if (_operationsNeedingAttention > 0) {
        _status = SyncStatus.needsAttention;
      } else if (serverFailure) {
        _status = SyncStatus.failed;
      } else if (failed) {
        _status = _networkAvailable ? SyncStatus.unstable : SyncStatus.offline;
      } else {
        _lastAttemptFailures = 0;
        _status = SyncStatus.completed;
      }
    } catch (_) {
      failed = true;
      _lastAttemptFailures++;
      _status = _networkAvailable ? SyncStatus.unstable : SyncStatus.offline;
      await _refreshCounts();
    } finally {
      _isSyncing = false;
      _notify();
    }
  }

  Future<String> _submitOperation(OutboxOperation operation) async {
    final isVisitOnly = operation.operationType == 'collection_visit';
    final isPaymentRequest =
        operation.operationType == 'collection_payment_request';
    if (!isVisitOnly && !isPaymentRequest) {
      throw const FormatException('unsupported_operation_type');
    }
    final hasLocation =
        operation.payload['latitude'] != null &&
        operation.payload['longitude'] != null &&
        operation.payload['accuracy_m'] != null &&
        operation.payload['location_captured_at'] != null;
    final params = isVisitOnly
        ? <String, dynamic>{
            'p_assignment_id': operation.payload['assignment_id'],
            'p_establishment_id': operation.payload['establishment_id'],
            'p_outcome': operation.payload['outcome'],
            'p_idempotency_key': operation.idempotencyKey,
            'p_visited_at': operation.payload['visited_at'],
            'p_notes': operation.payload['notes'],
            if (hasLocation) ...{
              'p_latitude': operation.payload['latitude'],
              'p_longitude': operation.payload['longitude'],
              'p_accuracy_m': operation.payload['accuracy_m'],
              'p_location_captured_at':
                  operation.payload['location_captured_at'],
            },
          }
        : <String, dynamic>{
            'p_assignment_id': operation.payload['assignment_id'],
            'p_establishment_id': operation.payload['establishment_id'],
            'p_obligation_id': operation.payload['obligation_id'],
            'p_amount': operation.payload['amount'],
            'p_method': operation.payload['method'],
            'p_idempotency_key': operation.idempotencyKey,
            'p_notes': operation.payload['notes'],
            if (hasLocation) ...{
              'p_latitude': operation.payload['latitude'],
              'p_longitude': operation.payload['longitude'],
              'p_accuracy_m': operation.payload['accuracy_m'],
              'p_location_captured_at':
                  operation.payload['location_captured_at'],
            },
          };
    final functionName = isVisitOnly
        ? 'record_offline_visit'
        : hasLocation
        ? 'record_collection_payment_request_with_location'
        : 'record_collection_payment_request';
    final result = await client!.rpc(functionName, params: params);
    if (result is! String)
      throw const FormatException('invalid_server_response');
    return result;
  }

  Future<_SyncScope> _cacheAuthorizedRecords() async {
    final currentClient = client;
    if (currentClient == null || currentClient.auth.currentUser == null) {
      return _SyncScope.denied;
    }
    final userId = currentClient.auth.currentUser!.id;
    final profile = await currentClient
        .from('profiles')
        .select('id, organization_id, status, display_name')
        .eq('id', userId)
        .maybeSingle();
    final organizationId = profile?['organization_id'] as String?;
    if (profile == null || profile['status'] != 'active') {
      await store.clearUserCache(userId);
      return _SyncScope.denied;
    }
    if (organizationId == null) {
      // Seul le super-administrateur (rôle global) fonctionne sans organisation.
      await store.clearUserCache(userId);
      final globalRoles = await currentClient
          .from('user_roles')
          .select('role_key')
          .eq('user_id', userId)
          .eq('role_key', 'super_admin')
          .isFilter('organization_id', null);
      return globalRoles.isEmpty ? _SyncScope.denied : _SyncScope.onlineOnly;
    }
    final cachedOrganizationId = await store.getMetadata('offline_org:$userId');
    if (cachedOrganizationId != null &&
        cachedOrganizationId != organizationId) {
      await store.clearUserCache(userId);
    }
    await store.setMetadata('offline_org:$userId', organizationId);

    final roleRows = await currentClient
        .from('user_roles')
        .select('role_key')
        .eq('organization_id', organizationId)
        .eq('user_id', userId);
    final roleKeys = roleRows.map((row) => row['role_key'] as String).toList();
    if (!roleKeys.contains('collector')) {
      // Le cache hors ligne reste réservé aux collecteurs.
      await store.clearUserCache(userId);
      return roleKeys.isEmpty ? _SyncScope.denied : _SyncScope.onlineOnly;
    }
    await store.cacheRecords(
      category: 'profile',
      organizationId: organizationId,
      userId: userId,
      records: [
        {
          'id': userId,
          'organization_id': organizationId,
          'status': profile['status'],
          'display_name': profile['display_name'],
          'role_keys': roleKeys,
        },
      ],
    );

    final assignments = await currentClient
        .from('mission_assignments')
        .select('id, mission_id')
        .eq('organization_id', organizationId)
        .eq('user_id', userId);
    if (assignments.isEmpty) {
      await store.cacheRecords(
        category: 'missions',
        organizationId: organizationId,
        userId: userId,
        records: [],
      );
      await store.cacheRecords(
        category: 'establishments',
        organizationId: organizationId,
        userId: userId,
        records: [],
      );
      await store.cacheRecords(
        category: 'appointments',
        organizationId: organizationId,
        userId: userId,
        records: [],
      );
      return _SyncScope.collector;
    }
    final missionIds = assignments
        .map((row) => row['mission_id'] as String)
        .toSet()
        .toList();
    final missions = await currentClient
        .from('missions')
        .select('id, title, scheduled_for, status, zone_id, zones(name)')
        .eq('organization_id', organizationId)
        .inFilter('id', missionIds)
        .limit(100);
    final assignmentByMission = {
      for (final row in assignments)
        row['mission_id'] as String: row['id'] as String,
    };
    final minimalMissions = missions
        .map(
          (row) => {
            'id': row['id'],
            'assignment_id': assignmentByMission[row['id']],
            'title': row['title'],
            'scheduled_for': row['scheduled_for'],
            'status': row['status'],
            'zone_id': row['zone_id'],
            'zone_name': (row['zones'] as Map<String, dynamic>?)?['name'],
          },
        )
        .toList();
    await store.cacheRecords(
      category: 'missions',
      organizationId: organizationId,
      userId: userId,
      records: minimalMissions,
    );

    final zoneIds = missions
        .map((row) => row['zone_id'] as String)
        .toSet()
        .toList();
    if (zoneIds.isNotEmpty) {
      final establishments = await currentClient
          .from('establishments')
          .select('id, name, address, zone_id')
          .eq('organization_id', organizationId)
          .inFilter('zone_id', zoneIds)
          .eq('is_active', true)
          .limit(500);
      await store.cacheRecords(
        category: 'establishments',
        organizationId: organizationId,
        userId: userId,
        records: establishments,
      );
    } else {
      await store.cacheRecords(
        category: 'establishments',
        organizationId: organizationId,
        userId: userId,
        records: [],
      );
    }

    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).toUtc();
    final end = start.add(const Duration(days: 7));
    final appointments = await currentClient
        .from('appointments')
        .select(
          'id, starts_at, status, establishment_id, establishments(name, address)',
        )
        .eq('organization_id', organizationId)
        .eq('assigned_to', userId)
        .gte('starts_at', start.toIso8601String())
        .lt('starts_at', end.toIso8601String())
        .limit(100);
    final minimalAppointments = appointments.map((row) {
      final establishment = row['establishments'] as Map<String, dynamic>?;
      return <String, dynamic>{
        'id': row['id'],
        'starts_at': row['starts_at'],
        'status': row['status'],
        'establishment_id': row['establishment_id'],
        'establishment_name': establishment?['name'],
        'address': establishment?['address'],
      };
    }).toList();
    await store.cacheRecords(
      category: 'appointments',
      organizationId: organizationId,
      userId: userId,
      records: minimalAppointments,
    );
    return _SyncScope.collector;
  }

  Future<void> _refreshCounts() async {
    final userId = client?.auth.currentUser?.id;
    if (userId == null) {
      _pendingOperations = 0;
      _operationsNeedingAttention = 0;
      return;
    }
    _pendingOperations = await store.pendingCount(ownerUserId: userId);
    _operationsNeedingAttention = await store.needsAttentionCount(
      ownerUserId: userId,
    );
  }

  Future<void> _loadMetadata() async {
    final value = await store.getMetadata('last_successful_sync');
    if (value != null) _lastSuccessfulSync = DateTime.tryParse(value);
  }

  String _safeErrorCode(String? code) => switch (code) {
    '23505' => 'duplicate_or_idempotency_conflict',
    '42501' => 'permission_denied',
    '22023' => 'server_validation_conflict',
    _ => 'server_rejected_operation',
  };

  void _notify() {
    notifyListeners();
    if (!_updates.isClosed) _updates.add(snapshot);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _authSubscription?.cancel();
    _updates.close();
    super.dispose();
  }
}

final offlineStoreProvider = Provider<OfflineStore?>((ref) => null);

final offlineSyncManagerProvider = Provider<OfflineSyncManager?>((ref) {
  final store = ref.watch(offlineStoreProvider);
  final client = ref.watch(supabaseClientProvider);
  if (store == null) return null;
  final manager = OfflineSyncManager(store: store, client: client);
  unawaited(manager.start());
  ref.onDispose(manager.dispose);
  return manager;
});

final offlineSyncSnapshotProvider = StreamProvider<OfflineSyncSnapshot?>((ref) {
  final manager = ref.watch(offlineSyncManagerProvider);
  if (manager == null) return Stream.value(null);
  return manager.snapshots;
});
