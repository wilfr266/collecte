import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';

/// Notification de l'utilisateur connecté (`public.notifications`, RLS
/// `notifications_read_own` : chacun ne lit que les siennes).
class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.readAt,
    required this.paymentId,
  });

  factory AppNotification.fromRow(Map<String, dynamic> row) => AppNotification(
    id: row['id'] as String,
    title: row['title'] as String,
    body: row['body'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    readAt: DateTime.tryParse(row['read_at'] as String? ?? ''),
    paymentId: row['payment_id'] as String?,
  );

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime? readAt;

  /// Paiement concerné, pour ouvrir son détail.
  final String? paymentId;

  bool get isRead => readAt != null;
}

/// Notifications à signaler sur l'appareil : non lues et postérieures à la
/// dernière alerte (une seule alerte par notification, même après relance).
/// Les plus récentes d'abord, au plus [max] pour éviter une rafale.
List<AppNotification> selectNewAlerts(
  List<AppNotification> notifications,
  DateTime lastAlerted, {
  int max = 3,
}) {
  final fresh =
      notifications
          .where((n) => !n.isRead && n.createdAt.isAfter(lastAlerted))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return fresh.take(max).toList();
}

class NotificationsRepository {
  const NotificationsRepository(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  Future<List<AppNotification>> list({int limit = 50}) async {
    final rows = await _client
        .from('notifications')
        .select('id, title, body, created_at, read_at, payment_id')
        .eq('recipient_id', _userId)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(AppNotification.fromRow).toList();
  }

  Future<int> unreadCount() async {
    final response = await _client
        .from('notifications')
        .select('id')
        .eq('recipient_id', _userId)
        .isFilter('read_at', null)
        .count(CountOption.exact);
    return response.count;
  }

  Future<void> markRead(String id) => _client
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', id)
      .eq('recipient_id', _userId)
      .isFilter('read_at', null);

  Future<void> markAllRead() => _client
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('recipient_id', _userId)
      .isFilter('read_at', null);
}

final notificationsRepositoryProvider = Provider<NotificationsRepository?>((
  ref,
) {
  final client = ref.watch(supabaseClientProvider);
  final userId = ref.watch(currentUserIdProvider);
  if (client == null || userId == null) return null;
  return NotificationsRepository(client, userId);
});

final notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>(
  (ref) async => await ref.watch(notificationsRepositoryProvider)?.list() ?? [],
);

/// Nombre de notifications non lues (pastille de l'onglet Alertes).
final unreadNotificationsProvider = FutureProvider.autoDispose<int>(
  (ref) async =>
      await ref.watch(notificationsRepositoryProvider)?.unreadCount() ?? 0,
);
