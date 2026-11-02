import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/live_refresh.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/notifications_repository.dart';

/// Notifications système de l'appareil (bannière, son, vibration courte).
///
/// Délivrées tant que le processus de l'application est actif : application
/// ouverte ou en arrière-plan récent. Application fermée, seul un envoi push
/// (FCM/APNs) peut réveiller le téléphone ; il n'est pas configuré.
/// Le mode silencieux, les réglages du système ou un refus de permission
/// peuvent empêcher la vibration : elle n'est jamais garantie.
class DeviceAlerts {
  DeviceAlerts._();

  static final instance = DeviceAlerts._();

  static const _channelId = 'payments';
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Appelé au toucher d'une notification (ouvre la rubrique Notifications).
  VoidCallback? onOpen;

  Future<void> _ensureReady() async {
    if (_ready || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (_) => onOpen?.call(),
    );
    _ready = true;
    // Application relancée par le toucher d'une notification.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) onOpen?.call();
  }

  /// Demande l'autorisation d'afficher des notifications (Android 13+, iOS).
  Future<void> requestPermission() async {
    try {
      await _ensureReady();
      if (!_ready) return;
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (error) {
      if (kDebugMode) debugPrint('[Alerts] Permission : $error');
    }
  }

  Future<void> show(AppNotification notification) async {
    try {
      await _ensureReady();
      if (!_ready) return;
      await _plugin.show(
        // Identifiant stable : une même notification remplace la précédente.
        id: notification.id.hashCode & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Paiements',
            channelDescription: 'Confirmation de vos paiements',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
            // Une vibration courte, sans répétition.
            vibrationPattern: Int64List.fromList([0, 300, 150, 300]),
            styleInformation: BigTextStyleInformation(notification.body),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
          ),
        ),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[Alerts] Affichage : $error');
    }
  }
}

/// Surveille les nouvelles notifications de l'utilisateur connecté (Realtime,
/// retour au premier plan, secours toutes les 30 s), met à jour la pastille et
/// déclenche une alerte système une seule fois par notification.
class NotificationAlerts extends ConsumerStatefulWidget {
  const NotificationAlerts({
    required this.child,
    required this.onOpen,
    super.key,
  });

  final Widget child;

  /// Ouverture de la rubrique Notifications depuis une alerte.
  final VoidCallback onOpen;

  @override
  ConsumerState<NotificationAlerts> createState() => _NotificationAlertsState();
}

class _NotificationAlertsState extends ConsumerState<NotificationAlerts> {
  static const _storage = FlutterSecureStorage();
  bool _checking = false;
  String? _preparedFor;

  String _key(String userId) => 'terenza.notifications.last_alert.$userId';

  @override
  void initState() {
    super.initState();
    DeviceAlerts.instance.onOpen = widget.onOpen;
  }

  Future<void> _prepare(String userId) async {
    if (_preparedFor == userId) return;
    _preparedFor = userId;
    await DeviceAlerts.instance.requestPermission();
    await _check();
  }

  Future<void> _check() async {
    final repository = ref.read(notificationsRepositoryProvider);
    final userId = ref.read(currentUserIdProvider);
    if (_checking || repository == null || userId == null) return;
    _checking = true;
    try {
      final notifications = await repository.list(limit: 20);
      final stored = await _storage.read(key: _key(userId));
      final lastAlerted = DateTime.tryParse(stored ?? '');
      final newest = notifications.isEmpty
          ? DateTime.now().toUtc()
          : notifications.first.createdAt;
      if (lastAlerted == null) {
        // Première ouverture sur ce téléphone : pas d'alerte pour l'historique.
        await _storage.write(
          key: _key(userId),
          value: newest.toIso8601String(),
        );
      } else {
        final alerts = selectNewAlerts(notifications, lastAlerted);
        for (final notification in alerts.reversed) {
          await DeviceAlerts.instance.show(notification);
        }
        if (alerts.isNotEmpty) {
          await _storage.write(
            key: _key(userId),
            value: alerts.first.createdAt.toIso8601String(),
          );
        }
      }
      ref.invalidate(unreadNotificationsProvider);
      ref.invalidate(notificationsProvider);
    } catch (error) {
      if (kDebugMode) debugPrint('[Alerts] Vérification : $error');
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return widget.child;
    unawaited(_prepare(userId));
    return LiveRefresh(
      channel: 'notification-alerts-$userId',
      sources: [
        LiveSource(
          'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: userId,
          ),
        ),
      ],
      onRefresh: _check,
      child: widget.child,
    );
  }
}
