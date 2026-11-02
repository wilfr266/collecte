import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/sync_status_banner.dart';
import '../../features/notifications/application/device_alerts.dart';
import '../../features/notifications/data/notifications_repository.dart';
import '../../features/auth/domain/access_decision.dart';
import '../../features/auth/domain/user_role.dart';
import '../../features/auth/presentation/auth_providers.dart';

/// Coque de navigation : les onglets dépendent de l'espace affiché.
///
/// L'espace est déduit de la route courante ; pour une route partagée
/// (profil, notifications) on retient l'espace principal de l'utilisateur.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  static const _collectorTabs = [
    _Tab(
      '/dashboard',
      Icons.space_dashboard_outlined,
      Icons.space_dashboard,
      'Accueil',
    ),
    _Tab('/clients', Icons.people_outline, Icons.people, 'Clients'),
    _Tab('/missions', Icons.route_outlined, Icons.route, 'Missions'),
    _Tab('/collections', Icons.payments_outlined, Icons.payments, 'Collectes'),
    _Tab('/profile', Icons.person_outline, Icons.person, 'Profil'),
  ];

  static const _adminTabs = [
    _Tab(
      '/admin',
      Icons.admin_panel_settings_outlined,
      Icons.admin_panel_settings,
      'Administration',
    ),
    _Tab(
      '/notifications',
      Icons.notifications_outlined,
      Icons.notifications,
      'Alertes',
    ),
    _Tab('/profile', Icons.person_outline, Icons.person, 'Profil'),
  ];

  static const _clientTabs = [
    _Tab(
      '/client',
      Icons.account_balance_wallet_outlined,
      Icons.account_balance_wallet,
      'Mon espace',
    ),
    _Tab(
      '/notifications',
      Icons.notifications_outlined,
      Icons.notifications,
      'Alertes',
    ),
    _Tab('/profile', Icons.person_outline, Icons.person, 'Profil'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = GoRouterState.of(context).uri.path;
    final space =
        MobileSpace.forPath(path) ??
        switch (ref.watch(accessDecisionProvider)) {
          AccessGranted(:final primarySpace) => primarySpace,
          _ => MobileSpace.collector,
        };
    final tabs = switch (space) {
      MobileSpace.admin => _adminTabs,
      MobileSpace.collector => _collectorTabs,
      MobileSpace.client => _clientTabs,
    };
    // La recherche terrain s'ouvre depuis « Clients » : même onglet actif.
    final matched = tabs.indexWhere(
      (tab) =>
          tab.route == path || (tab.route == '/clients' && path == '/search'),
    );

    final unread = ref.watch(unreadNotificationsProvider).valueOrNull ?? 0;
    Widget withBadge(_Tab tab, IconData icon) => tab.route == '/notifications'
        ? Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: Icon(icon),
          )
        : Icon(icon);

    // Alertes de paiement confirmé : surveillance, pastille et vibration.
    return NotificationAlerts(
      onOpen: () => context.go('/notifications'),
      child: Scaffold(
        body: Column(
          children: [
            SyncStatusBanner(offlineCapable: space == MobileSpace.collector),
            Expanded(child: child),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: matched < 0 ? 0 : matched,
          onDestinationSelected: (index) => context.go(tabs[index].route),
          destinations: [
            for (final tab in tabs)
              NavigationDestination(
                icon: withBadge(tab, tab.icon),
                selectedIcon: withBadge(tab, tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      ),
    );
  }
}

class _Tab {
  const _Tab(this.route, this.icon, this.selectedIcon, this.label);

  final String route;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
