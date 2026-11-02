import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../auth/presentation/auth_providers.dart';

final assignedMissionsProvider = FutureProvider.autoDispose<List<_Mission>>((
  ref,
) async {
  final client = ref.watch(supabaseClientProvider);
  final profile = await ref.watch(currentProfileProvider.future);
  if (client == null || profile?.organizationId == null) {
    throw StateError('Session de collecte indisponible.');
  }

  final assignmentRows = await client
      .from('mission_assignments')
      .select('id, mission_id')
      .eq('organization_id', profile!.organizationId!)
      .eq('user_id', profile.id);
  if (assignmentRows.isEmpty) return [];

  final missionIds = assignmentRows
      .map((row) => row['mission_id'] as String)
      .toSet()
      .toList();
  final missionRows = await client
      .from('missions')
      .select('id, title, scheduled_for, status, zone_id, zones(name)')
      .eq('organization_id', profile.organizationId!)
      .inFilter('id', missionIds)
      .order('scheduled_for', ascending: false)
      .limit(50);
  final assignmentByMission = {
    for (final row in assignmentRows)
      row['mission_id'] as String: row['id'] as String,
  };
  final assignmentIds = assignmentRows
      .map((row) => row['id'] as String)
      .toList();
  final collectionRows = await client
      .from('collections')
      .select('mission_assignment_id')
      .eq('organization_id', profile.organizationId!)
      .eq('collector_id', profile.id)
      .inFilter('mission_assignment_id', assignmentIds);
  final progressByAssignment = <String, int>{};
  for (final row in collectionRows) {
    final assignmentId = row['mission_assignment_id'] as String?;
    if (assignmentId != null) {
      progressByAssignment.update(
        assignmentId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
  }

  return missionRows.map((row) {
    final zone = row['zones'] as Map<String, dynamic>?;
    return _Mission(
      id: row['id'] as String,
      assignmentId: assignmentByMission[row['id']]!,
      title: row['title'] as String,
      zoneId: row['zone_id'] as String,
      zone: zone?['name'] as String? ?? 'Zone non renseignée',
      scheduledFor: DateTime.parse(row['scheduled_for'] as String),
      status: row['status'] as String,
      completedVisits:
          progressByAssignment[assignmentByMission[row['id']]] ?? 0,
    );
  }).toList();
});

class MissionsPage extends ConsumerWidget {
  const MissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missions = ref.watch(assignedMissionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mes missions')),
      body: missions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _MissionMessage(
          icon: Icons.cloud_off_outlined,
          message: 'Les missions ne sont pas disponibles. Vérifiez le réseau.',
          action: FilledButton.tonalIcon(
            onPressed: () => ref.invalidate(assignedMissionsProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('Réessayer'),
          ),
        ),
        data: (items) => items.isEmpty
            ? const _MissionMessage(
                icon: Icons.route_outlined,
                message: 'Aucune mission ne vous est affectée.',
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(assignedMissionsProvider);
                  await ref.read(assignedMissionsProvider.future);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _MissionTile(mission: items[index]),
                ),
              ),
      ),
    );
  }
}

class _MissionTile extends StatelessWidget {
  const _MissionTile({required this.mission});

  final _Mission mission;

  @override
  Widget build(BuildContext context) {
    final date = mission.scheduledFor.toLocal();
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(Icons.route_outlined),
        title: Text(mission.title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${mission.zone}\n${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} · ${_statusLabel(mission.status)} · ${mission.completedVisits} visites',
          ),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mission.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text('Zone · ${mission.zone}'),
                  Text('Statut · ${_statusLabel(mission.status)}'),
                  Text('Visites enregistrées · ${mission.completedVisits}'),
                  const SizedBox(height: 12),
                  _MissionFigures(assignmentId: mission.assignmentId),
                  const SizedBox(height: 12),
                  Text(
                    'Établissements de la zone',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _MissionEstablishments(zoneId: mission.zoneId),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clients (établissements et contribuables) de la zone d'une mission.
///
/// Lecture filtrée par RLS (`can_access_establishment`) : seules les zones
/// des missions affectées et actives sont visibles.
final _zoneEstablishmentsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, zoneId) async {
      final client = ref.watch(supabaseClientProvider);
      if (client == null) return [];
      return client
          .from('establishments')
          .select('id, name, address, taxpayers(legal_name)')
          .eq('zone_id', zoneId)
          .eq('is_active', true)
          .order('name')
          .limit(100);
    });

class _MissionEstablishments extends ConsumerWidget {
  const _MissionEstablishments({required this.zoneId});

  final String zoneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final establishments = ref.watch(_zoneEstablishmentsProvider(zoneId));
    return establishments.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, stackTrace) =>
          const Text('Établissements indisponibles pour cette mission.'),
      data: (items) => items.isEmpty
          ? const Text('Aucun établissement accessible dans cette zone.')
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final row in items)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.storefront_outlined),
                      title: Text(row['name'] as String),
                      subtitle: Text(
                        [
                          (row['taxpayers']
                                  as Map<String, dynamic>?)?['legal_name']
                              as String?,
                          row['address'] as String?,
                        ].whereType<String>().join(' · '),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Bilan réel de la mission pour le collecteur : clients visités et
/// paiements enregistrés sur cette affectation (RLS : ses propres collectes).
/// Aucun objectif chiffré n'existe dans le modèle : rien n'est inventé.
class MissionFigures {
  const MissionFigures({
    required this.clientsVisited,
    required this.confirmedAmount,
    required this.confirmedCount,
    required this.pendingAmount,
    required this.pendingCount,
  });

  final int clientsVisited;
  final int confirmedAmount;
  final int confirmedCount;
  final int pendingAmount;
  final int pendingCount;
}

final _missionFiguresProvider = FutureProvider.autoDispose
    .family<MissionFigures, String>((ref, assignmentId) async {
      final client = ref.watch(supabaseClientProvider);
      if (client == null) throw StateError('service_unavailable');
      final visits = await client
          .from('collections')
          .select('establishment_id')
          .eq('mission_assignment_id', assignmentId);
      final payments = await client
          .from('payments')
          .select('amount, status, collections!inner(mission_assignment_id)')
          .eq('collections.mission_assignment_id', assignmentId);
      int sum(String status) => payments
          .where((p) => p['status'] == status)
          .fold(0, (total, p) => total + (p['amount'] as num).toInt());
      int count(String status) =>
          payments.where((p) => p['status'] == status).length;
      return MissionFigures(
        clientsVisited: visits.map((v) => v['establishment_id']).toSet().length,
        confirmedAmount: sum('confirmed'),
        confirmedCount: count('confirmed'),
        pendingAmount: sum('pending'),
        pendingCount: count('pending'),
      );
    });

class _MissionFigures extends ConsumerWidget {
  const _MissionFigures({required this.assignmentId});

  final String assignmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final figures = ref.watch(_missionFiguresProvider(assignmentId));
    return figures.when(
      loading: () => const LinearProgressIndicator(),
      error: (error, stackTrace) => Row(
        children: [
          const Expanded(
            child: Text('Le bilan de la mission n’a pas pu être chargé.'),
          ),
          TextButton(
            onPressed: () =>
                ref.invalidate(_missionFiguresProvider(assignmentId)),
            child: const Text('Réessayer'),
          ),
        ],
      ),
      data: (f) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bilan de la mission',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Encaissé · ${CurrencyFormatter.formatCfa(f.confirmedAmount)} (${f.confirmedCount} paiement(s))',
              ),
              if (f.pendingCount > 0)
                Text(
                  'En attente de confirmation · ${CurrencyFormatter.formatCfa(f.pendingAmount)} (${f.pendingCount})',
                ),
              Text('Clients visités · ${f.clientsVisited}'),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissionMessage extends StatelessWidget {
  const _MissionMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

class _Mission {
  const _Mission({
    required this.id,
    required this.assignmentId,
    required this.title,
    required this.zoneId,
    required this.zone,
    required this.scheduledFor,
    required this.status,
    required this.completedVisits,
  });

  final String id;
  final String assignmentId;
  final String title;
  final String zoneId;
  final String zone;
  final DateTime scheduledFor;
  final String status;
  final int completedVisits;
}

String _statusLabel(String status) => switch (status) {
  'assigned' => 'Affectée',
  'in_progress' => 'En cours',
  'completed' => 'Terminée',
  'cancelled' => 'Annulée',
  _ => 'Brouillon',
};
