import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/dashboard_summary.dart';

class SupabaseDashboardRepository {
  const SupabaseDashboardRepository(this._client);

  final SupabaseClient _client;

  Future<DashboardSummary> load({
    required String userId,
    required String organizationId,
    required String displayName,
  }) async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day).toUtc();
    final startOfTomorrow = DateTime(now.year, now.month, now.day + 1).toUtc();
    final start = startOfDay.toIso8601String();
    final end = startOfTomorrow.toIso8601String();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final assignments = await _client
        .from('mission_assignments')
        .select('mission_id')
        .eq('organization_id', organizationId)
        .eq('user_id', userId);
    final missionIds = assignments
        .map((row) => row['mission_id'] as String)
        .toSet()
        .toList();

    final missionRows = missionIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _client
              .from('missions')
              .select('id, title, scheduled_for, status, zones(name)')
              .eq('organization_id', organizationId)
              .inFilter('id', missionIds)
              .gte('scheduled_for', today)
              .order('scheduled_for')
              .limit(10);

    final collectionRows = await _client
        .from('collections')
        .select('id')
        .eq('organization_id', organizationId)
        .eq('collector_id', userId)
        .gte('visited_at', start)
        .lt('visited_at', end);

    final paymentRows = await _client
        .from('payments')
        .select('amount')
        .eq('organization_id', organizationId)
        .eq('recorded_by', userId)
        .eq('status', 'confirmed')
        .gte('confirmed_at', start)
        .lt('confirmed_at', end);

    final appointmentRows = await _client
        .from('appointments')
        .select('starts_at')
        .eq('organization_id', organizationId)
        .eq('assigned_to', userId)
        .eq('status', 'scheduled')
        .gte('starts_at', start)
        .lt('starts_at', end)
        .order('starts_at')
        .limit(10);

    final notificationRows = await _client
        .from('notifications')
        .select('id')
        .eq('organization_id', organizationId)
        .eq('recipient_id', userId)
        .isFilter('read_at', null)
        .limit(100);

    final missions = missionRows.map((row) {
      final zone = row['zones'] as Map<String, dynamic>?;
      return DashboardMission(
        title: row['title'] as String,
        zone: zone?['name'] as String? ?? 'Zone non renseignée',
        status: row['status'] as String,
        scheduledFor: DateTime.parse(row['scheduled_for'] as String),
      );
    }).toList();
    final amountCollected = paymentRows.fold<int>(
      0,
      (sum, row) => sum + (row['amount'] as num).toInt(),
    );

    return DashboardSummary(
      displayName: displayName,
      missionsToday: missions
          .where(
            (m) =>
                m.scheduledFor.year == now.year &&
                m.scheduledFor.month == now.month &&
                m.scheduledFor.day == now.day,
          )
          .length,
      collectionsToday: collectionRows.length,
      amountCollectedCfa: amountCollected,
      appointmentsToday: appointmentRows.length,
      unreadNotifications: notificationRows.length,
      missions: missions,
      mainZone: missions.firstOrNull?.zone,
      nextAppointment: appointmentRows.firstOrNull?['starts_at'] as String?,
    );
  }
}
