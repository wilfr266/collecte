import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/clients/presentation/clients_page.dart';
import '../../features/admin/presentation/admin_page.dart';
import '../../features/auth/presentation/auth_gate.dart';
import '../../features/auth/presentation/password_recovery_pages.dart';
import '../../features/auth/domain/access_decision.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/agenda/presentation/agenda_page.dart';
import '../../features/cash/presentation/cash_page.dart';
import '../../features/client/presentation/client_page.dart';
import '../../features/collections/presentation/collections_page.dart';
import '../../features/collections/presentation/new_collection_page.dart';
import '../../features/contributors/presentation/contributor_search_page.dart';
import '../../features/dashboard/presentation/dashboard_page.dart';
import '../../features/dashboard/presentation/offline_overview_page.dart';
import '../../features/missions/presentation/missions_page.dart';
import '../../features/notifications/presentation/notifications_page.dart';
import '../../features/profile/presentation/profile_page.dart';
import '../../features/receipts/presentation/receipts_page.dart';
import '../../features/transactions/presentation/transactions_page.dart';
import '../../features/zones/presentation/zones_page.dart';
import '../shell/app_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // L'écoute maintient la décision en vie et rafraîchit le routeur à chaque
  // changement de session, de profil, de rôles ou de réseau.
  final refresh = _RouterRefresh();
  var decision = ref.read(accessDecisionProvider);
  var recoveryPending = ref.read(passwordRecoveryProvider);
  ref.listen<AccessDecision>(accessDecisionProvider, (previous, next) {
    decision = next;
    refresh.notify();
  });
  ref.listen<bool>(passwordRecoveryProvider, (previous, next) {
    recoveryPending = next;
    refresh.notify();
  });
  ref.onDispose(refresh.dispose);
  final router = GoRouter(
    initialLocation: '/auth',
    refreshListenable: refresh,
    redirect: (context, state) => accessRedirect(
      decision,
      state.matchedLocation,
      recoveryPending: recoveryPending,
    ),
    routes: [
      GoRoute(path: '/auth', builder: (context, state) => const AuthGate()),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordPage(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => const ResetPasswordPage(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          _route('/admin', const AdminPage()),
          _route('/client', const ClientPage()),
          _route('/dashboard', const DashboardPage()),
          _route('/offline', const OfflineOverviewPage()),
          _route('/missions', const MissionsPage()),
          _route('/zones', const ZonesPage()),
          _route('/clients', const ClientsPage()),
          _route('/search', const ContributorSearchPage()),
          _route('/agenda', const AgendaPage()),
          _route('/collections', const CollectionsPage()),
          _route('/new-collection', const NewCollectionPage()),
          _route('/profile', const ProfilePage()),
          _route('/notifications', const NotificationsPage()),
          _route('/receipts', const ReceiptsPage()),
          _route('/transactions', const TransactionsPage()),
          _route('/cash', const CashPage()),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class _RouterRefresh extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Les droits d'accès sont appliqués par [accessRedirect] ; RLS reste la
/// frontière d'autorisation réelle.
GoRoute _route(String path, Widget page) =>
    GoRoute(path: path, builder: (context, state) => page);
