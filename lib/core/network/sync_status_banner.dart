import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'offline_sync_manager.dart';

class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({this.offlineCapable = true, super.key});

  /// Faux pour les espaces sans file d'attente ni cache local (client,
  /// administration) : compteur d'opérations et accès aux données locales
  /// masqués.
  final bool offlineCapable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(offlineSyncManagerProvider);
    final snapshot = ref.watch(offlineSyncSnapshotProvider).valueOrNull;
    final store = ref.watch(offlineStoreProvider);
    if (store == null) {
      return const _StatusStrip(
        icon: Icons.storage_rounded,
        label: 'Stockage hors ligne indisponible',
        color: Color(0xFFB45309),
      );
    }
    if (snapshot == null) {
      return const _StatusStrip(
        icon: Icons.sync,
        label: 'Connexion en cours de vérification',
        color: Color(0xFF64748B),
      );
    }

    final (label, icon, color) = _statusAppearance(snapshot.status);
    final lastSync = snapshot.lastSuccessfulSync;
    final lastSyncLabel = lastSync == null
        ? 'Jamais synchronisé'
        : 'Sync · ${_timeAgo(lastSync)}';
    final conflictLabel = snapshot.operationsNeedingAttention == 0
        ? null
        : 'À traiter · ${snapshot.operationsNeedingAttention}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: color.withValues(alpha: 0.12),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  if (offlineCapable)
                    Text('${snapshot.pendingOperations} en attente'),
                  Text(lastSyncLabel),
                  if (conflictLabel != null)
                    Text(
                      conflictLabel,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            if (manager != null && snapshot.status != SyncStatus.syncing)
              IconButton(
                tooltip: 'Synchroniser maintenant',
                visualDensity: VisualDensity.compact,
                onPressed: () => manager.syncNow(forceRetry: true),
                icon: const Icon(Icons.sync),
              ),
            if (offlineCapable &&
                (snapshot.status == SyncStatus.offline ||
                    snapshot.status == SyncStatus.unstable ||
                    snapshot.status == SyncStatus.failed))
              TextButton(
                onPressed: () => context.go('/offline'),
                child: const Text('Données locales'),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: color.withValues(alpha: 0.12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    child: SafeArea(
      bottom: false,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

(String, IconData, Color) _statusAppearance(SyncStatus status) =>
    switch (status) {
      SyncStatus.connected => (
        'Connecté',
        Icons.cloud_done_outlined,
        const Color(0xFF15803D),
      ),
      SyncStatus.unstable => (
        'Connexion instable',
        Icons.signal_wifi_bad,
        const Color(0xFFB45309),
      ),
      SyncStatus.offline => (
        'Hors ligne',
        Icons.cloud_off_outlined,
        const Color(0xFFB91C1C),
      ),
      SyncStatus.syncing => (
        'Synchronisation en cours',
        Icons.sync,
        const Color(0xFF2563EB),
      ),
      SyncStatus.completed => (
        'Synchronisation terminée',
        Icons.cloud_done,
        const Color(0xFF15803D),
      ),
      SyncStatus.failed => (
        'Échec de synchronisation',
        Icons.error_outline,
        const Color(0xFFB91C1C),
      ),
      SyncStatus.needsAttention => (
        'Intervention requise',
        Icons.warning_amber,
        const Color(0xFFB45309),
      ),
    };

String _timeAgo(DateTime value) {
  final difference = DateTime.now().difference(value.toLocal());
  if (difference.inMinutes < 1) return 'à l’instant';
  if (difference.inHours < 1) return 'il y a ${difference.inMinutes} min';
  if (difference.inDays < 1) return 'il y a ${difference.inHours} h';
  return '${value.toLocal().day.toString().padLeft(2, '0')}/${value.toLocal().month.toString().padLeft(2, '0')}';
}
