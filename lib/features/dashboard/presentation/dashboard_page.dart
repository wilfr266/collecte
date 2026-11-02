import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../features/auth/presentation/auth_providers.dart';
import '../../../shared/widgets/dashboard_metric_card.dart';
import '../data/supabase_dashboard_repository.dart';
import '../domain/dashboard_summary.dart';

final dashboardSummaryProvider = FutureProvider.autoDispose<DashboardSummary>((
  ref,
) async {
  final client = ref.watch(supabaseClientProvider);
  final repository = ref.watch(authRepositoryProvider);
  if (client == null || repository == null) {
    throw StateError('service_not_configured');
  }

  final profile = await ref.watch(currentProfileProvider.future);
  if (profile == null || profile.organizationId == null || !profile.isActive) {
    throw StateError('Le profil actif du collecteur est indisponible.');
  }

  return SupabaseDashboardRepository(client).load(
    userId: profile.id,
    organizationId: profile.organizationId!,
    displayName: profile.displayName,
  );
});

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(dashboardSummaryProvider);
    return summary.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, stackTrace) => _DashboardError(
        message:
            'Les données ne sont pas disponibles. Vérifiez le réseau puis réessayez.',
        onRetry: () => ref.invalidate(dashboardSummaryProvider),
      ),
      data: (value) => _DashboardContent(
        summary: value,
        onRefresh: () async {
          ref.invalidate(dashboardSummaryProvider);
          await ref.read(dashboardSummaryProvider.future);
        },
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({required this.summary, required this.onRefresh});

  final DashboardSummary summary;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                title: const Text('TERENZA'),
                floating: true,
                actions: [
                  IconButton(
                    tooltip: 'Notifications',
                    onPressed: () => context.go('/notifications'),
                    icon: Badge(
                      isLabelVisible: summary.unreadNotifications > 0,
                      label: Text('${summary.unreadNotifications}'),
                      child: const Icon(Icons.notifications_outlined),
                    ),
                  ),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                sliver: SliverList.list(
                  children: [
                    Text(
                      'Bonjour ${summary.displayName}',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _frenchDate(DateTime.now()),
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      summary.mainZone == null
                          ? 'Aucune zone active'
                          : 'Zone principale · ${summary.mainZone}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    Text('Aujourd’hui', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    _DashboardMetrics(summary: summary),
                    const SizedBox(height: 24),
                    Text('Actions rapides', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: () => context.go('/new-collection'),
                          icon: const Icon(Icons.add),
                          label: const Text('Nouvelle visite'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => context.go('/agenda'),
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Mon agenda'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text('Missions à venir', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 10),
                    if (summary.missions.isEmpty)
                      const _EmptyState(message: 'Aucune mission à venir.')
                    else
                      ...summary.missions.map(
                        (mission) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.route_outlined),
                            title: Text(mission.title),
                            subtitle: Text(
                              '${mission.zone} · ${_missionStatus(mission.status)}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.go('/missions'),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (summary.nextAppointment != null)
                      Text(
                        'Prochain rendez-vous · ${_formatTime(summary.nextAppointment!)}',
                      ),
                    const SizedBox(height: 16),
                    const _SyncStatus(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardMetrics extends StatelessWidget {
  const _DashboardMetrics({required this.summary});

  final DashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 128,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      children: [
        DashboardMetricCard(
          label: 'Missions prévues',
          value: '${summary.missionsToday}',
          icon: Icons.route_outlined,
        ),
        DashboardMetricCard(
          label: 'Collectes réalisées',
          value: '${summary.collectionsToday}',
          icon: Icons.task_alt,
        ),
        DashboardMetricCard(
          label: 'Montant collecté',
          value: CurrencyFormatter.formatCfa(summary.amountCollectedCfa),
          icon: Icons.payments_outlined,
        ),
        DashboardMetricCard(
          label: 'Rendez-vous',
          value: '${summary.appointmentsToday}',
          icon: Icons.calendar_month_outlined,
        ),
      ],
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Icon(Icons.cloud_done_outlined, size: 18),
      SizedBox(width: 8),
      Text('Données à jour'),
    ],
  );
}

String _missionStatus(String status) => switch (status) {
  'assigned' => 'Affectée',
  'in_progress' => 'En cours',
  'completed' => 'Terminée',
  'cancelled' => 'Annulée',
  _ => 'Brouillon',
};

String _frenchDate(DateTime date) {
  const months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

String _formatTime(String value) {
  final date = DateTime.parse(value).toLocal();
  return '${date.hour.toString().padLeft(2, '0')} h ${date.minute.toString().padLeft(2, '0')}';
}
