import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_decision.dart';
import 'auth_providers.dart';
import 'login_page.dart';

/// Écran de la route `/auth` : connexion commune et états d'accès.
///
/// La décision est calculée par [accessDecisionProvider] (statut → rôles →
/// organisation → espace) ; la redirection vers l'espace est faite par le
/// routeur ([accessRedirect]). Ce widget ne fait qu'afficher l'état courant.
///
/// **Statut ≠ Rôle** :
/// - Le statut (`profiles.status`) contrôle si le compte peut fonctionner.
/// - Le rôle (`user_roles.role_key`) détermine ce que l'utilisateur peut faire.
/// Ces deux dimensions sont vérifiées indépendamment.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(accessDecisionProvider)) {
      AccessNotConfigured(:final configured) => _ConfigurationRequiredPage(
        configured: configured,
      ),
      AccessSignedOut() => const LoginPage(),
      // Accordé : le routeur redirige vers l'espace au prochain cycle.
      AccessChecking() || AccessGranted() => const _AuthLoadingPage(),
      AccessUnavailable(:final message) => _MessagePage(
        title: 'Connexion indisponible',
        message: message,
        actionLabel: 'Réessayer',
        onAction: () => retryAccessCheck(ref),
        secondaryLabel: 'Se déconnecter',
        onSecondary: () => ref.read(authRepositoryProvider)?.signOut(),
      ),
      AccessDenied(:final reason) => _AccessDeniedPage(reason: reason),
    };
  }
}

// ── Pages internes ────────────────────────────────────────────────────────────

class _ConfigurationRequiredPage extends StatelessWidget {
  const _ConfigurationRequiredPage({required this.configured});

  final bool configured;

  @override
  Widget build(BuildContext context) => _MessagePage(
    title: configured ? 'Connexion indisponible' : 'Configuration requise',
    message: configured
        ? 'Le service Terenza est momentanément indisponible. Fermez l’application puis réessayez.'
        : 'L’application n’est pas encore configurée. Contactez votre administrateur.',
  );
}

class _AuthLoadingPage extends StatelessWidget {
  const _AuthLoadingPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Refus d'accès contrôlé, adapté au motif.
///
/// - statut (`pending`, `suspended`, `disabled`, inconnu) ;
/// - `unassigned` : profil actif sans organisation → écran d'assistance ;
/// - `noMobileRole` : profil actif et rattaché sans rôle mobile.
class _AccessDeniedPage extends ConsumerWidget {
  const _AccessDeniedPage({required this.reason});

  final AccessDenialReason reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (title, message) = switch (reason) {
      AccessDenialReason.pending => (
        'Compte en attente',
        'Votre compte a bien été créé mais n’est pas encore approuvé. Un administrateur doit l’activer avant que vous puissiez accéder à l’application.',
      ),
      AccessDenialReason.suspended => (
        'Compte suspendu',
        'Votre compte est suspendu. Aucune fonction n’est accessible tant qu’il n’est pas réactivé. Contactez votre superviseur ou votre administration.',
      ),
      AccessDenialReason.disabled => (
        'Compte désactivé',
        'Votre compte est désactivé. Contactez votre administrateur si vous pensez qu’il s’agit d’une erreur.',
      ),
      AccessDenialReason.unknownStatus => (
        'Accès refusé',
        'Le statut de votre compte n’est pas reconnu par cette version de l’application. Mettez l’application à jour ou contactez votre administrateur.',
      ),
      AccessDenialReason.missingProfile => (
        'Profil introuvable',
        'Aucun profil n’est associé à ce compte. Contactez votre administrateur.',
      ),
      AccessDenialReason.unassigned => (
        'Rattachement requis',
        'Votre compte est actif mais n’est rattaché à aucune organisation. Transmettez l’identifiant ci-dessous à votre administration pour qu’elle vous rattache.',
      ),
      AccessDenialReason.noMobileRole => (
        'Accès refusé',
        'Votre compte ne dispose d’aucun rôle pris en charge par l’application mobile (administrateur, collecteur ou client). Contactez votre administrateur.',
      ),
    };
    // Les situations qui peuvent évoluer côté administration proposent une
    // nouvelle vérification ; suspension et désactivation non.
    final canRecheck = switch (reason) {
      AccessDenialReason.suspended || AccessDenialReason.disabled => false,
      _ => true,
    };
    final user = ref.watch(authRepositoryProvider)?.currentUser;
    return _MessagePage(
      title: title,
      message: message,
      details: reason == AccessDenialReason.unassigned && user != null
          ? _AssistanceDetails(email: user.email, userId: user.id)
          : null,
      actionLabel: canRecheck ? 'Vérifier à nouveau' : null,
      onAction: canRecheck ? () => retryAccessCheck(ref) : null,
      secondaryLabel: 'Se déconnecter',
      onSecondary: () => ref.read(authRepositoryProvider)?.signOut(),
    );
  }
}

class _AssistanceDetails extends StatelessWidget {
  const _AssistanceDetails({required this.email, required this.userId});

  final String? email;
  final String userId;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (email != null) SelectableText('Compte · $email'),
          SelectableText('Identifiant du compte · $userId'),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: userId));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Identifiant copié.')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copier l’identifiant'),
          ),
        ],
      ),
    ),
  );
}

class _MessagePage extends StatelessWidget {
  const _MessagePage({
    required this.title,
    required this.message,
    this.details,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String title;
  final String message;
  final Widget? details;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (details != null) ...[const SizedBox(height: 16), details!],
              if (actionLabel != null) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
