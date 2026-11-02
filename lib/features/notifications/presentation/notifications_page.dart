import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/state_views.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/data/payments_repository.dart';
import '../../payments/presentation/client_finance_screen.dart';
import '../../payments/presentation/taxpayer_payments_panel.dart';
import '../data/notifications_repository.dart';

/// Rubrique Notifications : nouvelles et déjà lues, date et heure, accès au
/// paiement concerné. La liste est tenue à jour par `NotificationAlerts`
/// (Realtime et actualisation de secours) installé dans la coque.
class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(notificationsProvider);
    ref.invalidate(unreadNotificationsProvider);
    await ref.read(notificationsProvider.future);
  }

  Future<void> _markAllRead(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(notificationsRepositoryProvider)?.markAllRead();
      await _refresh(ref);
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Impossible de mettre à jour vos notifications.');
      }
    }
  }

  /// Ouverture : marquée comme lue, puis détail du paiement s'il existe.
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    AppNotification notification,
  ) async {
    if (!notification.isRead) {
      try {
        await ref
            .read(notificationsRepositoryProvider)
            ?.markRead(notification.id);
        await _refresh(ref);
      } catch (_) {
        // Le paiement reste consultable même si le marquage échoue.
      }
    }
    final paymentId = notification.paymentId;
    if (paymentId == null || !context.mounted) return;
    try {
      final location = await ref
          .read(paymentsRepositoryProvider)
          ?.location(paymentId);
      if (location == null || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ClientFinanceScreen(
            taxpayerId: location.taxpayerId,
            title: location.taxpayerName,
            initialMonth: location.month,
            highlightPaymentId: paymentId,
            organizationId: ref
                .read(currentProfileProvider)
                .valueOrNull
                ?.organizationId,
          ),
        ),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[Notifications] Ouverture : $error');
      if (context.mounted) {
        _snack(
          context,
          'Ce paiement ne peut pas être affiché pour le moment. Réessayez dans quelques instants.',
        );
      }
    }
  }

  void _snack(BuildContext context, String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationsProvider);
    final hasUnread = notifications.valueOrNull?.any((n) => !n.isRead) ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (hasUnread)
            TextButton(
              onPressed: () => _markAllRead(context, ref),
              child: const Text('Tout marquer comme lu'),
            ),
        ],
      ),
      body: notifications.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => StateMessageView.error(
          message:
              'Vos notifications n’ont pas pu être chargées. Réessayez dans quelques instants.',
          onRetry: () => ref.invalidate(notificationsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const StateMessageView(
              icon: Icons.notifications_none,
              message:
                  'Aucune notification pour le moment. Vous serez prévenu ici dès qu’un paiement sera confirmé.',
            );
          }
          final unread = items.where((n) => !n.isRead).toList();
          final read = items.where((n) => n.isRead).toList();
          return RefreshIndicator(
            onRefresh: () => _refresh(ref),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (unread.isNotEmpty) ...[
                  _SectionTitle('Nouvelles (${unread.length})'),
                  for (final n in unread)
                    _NotificationTile(
                      notification: n,
                      onTap: () => _open(context, ref, n),
                    ),
                ],
                if (read.isNotEmpty) ...[
                  const _SectionTitle('Déjà lues'),
                  for (final n in read)
                    _NotificationTile(
                      notification: n,
                      onTap: () => _open(context, ref, n),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final theme = Theme.of(context);
    final at = n.createdAt.toLocal();
    return Card(
      color: n.isRead ? null : theme.colorScheme.primaryContainer,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          n.paymentId != null
              ? Icons.verified_outlined
              : n.isRead
              ? Icons.notifications_none
              : Icons.notifications_active_outlined,
        ),
        title: Text(
          n.title,
          style: n.isRead ? null : const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            n.body,
            '${dayLabel(at)} · ${timeLabel(at)}',
            if (n.paymentId != null) 'Toucher pour voir le paiement',
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: n.isRead
            ? null
            : Icon(Icons.circle, size: 10, color: theme.colorScheme.primary),
      ),
    );
  }
}
