import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/theme_mode_provider.dart';
import '../../auth/domain/access_decision.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_providers.dart';
import 'organization_card.dart';

/// Profil commun à tous les rôles : identité, organisation, statut, rôles et
/// liens vers les fonctions ouvertes par les rôles de l'utilisateur.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    final user = ref.watch(authRepositoryProvider)?.currentUser;
    final decision = ref.watch(accessDecisionProvider);
    final granted = decision is AccessGranted ? decision : null;
    final roles = granted?.roles ?? const <UserRole>[];
    final spaces = granted?.spaces ?? const <MobileSpace>[];
    final isCollector = spaces.contains(MobileSpace.collector);
    final offline = granted?.offline ?? false;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Profil', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 24),
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text(profile?.displayName ?? 'Mon compte'),
          subtitle: Text(
            [
              user?.email,
              profile?.phone,
            ].whereType<String>().where((p) => p.isNotEmpty).join(' · '),
          ),
          trailing: profile == null || offline
              ? null
              : IconButton(
                  tooltip: 'Modifier mes coordonnées',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => _EditContactSheet(profile: profile),
                  ),
                ),
        ),
        Wrap(
          spacing: 8,
          children: [
            if (profile != null)
              Chip(label: Text('Compte ${profile.status.label.toLowerCase()}')),
            for (final role in roles) Chip(label: Text(role.label)),
          ],
        ),
        const SizedBox(height: 8),
        if (!offline) const OrganizationCard(),
        const SizedBox(height: 12),
        if (spaces.length > 1) ...[
          Text('Mes espaces', style: Theme.of(context).textTheme.titleMedium),
          for (final space in spaces)
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(space.label),
              onTap: () => context.go(space.homeRoute),
            ),
          const SizedBox(height: 12),
        ],
        if (isCollector) ...[
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Mes zones'),
            onTap: () => context.go('/zones'),
          ),
          ListTile(
            leading: const Icon(Icons.swap_vert),
            title: const Text('Mes transactions'),
            onTap: () => context.go('/transactions'),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Agenda'),
            onTap: () => context.go('/agenda'),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Reçus'),
            onTap: () => context.go('/receipts'),
          ),
        ],
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Notifications'),
          onTap: () => context.go('/notifications'),
        ),
        // La caisse est réservée aux caissiers affectés à un registre.
        if (isCollector && roles.contains(UserRole.cashier))
          ListTile(
            leading: const Icon(Icons.point_of_sale_outlined),
            title: const Text('Caisse'),
            onTap: () => context.go('/cash'),
          ),
        if (!offline)
          ListTile(
            leading: const Icon(Icons.lock_reset),
            title: const Text('Changer mon mot de passe'),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (context) => const _ChangePasswordSheet(),
            ),
          ),
        const SizedBox(height: 12),
        Text('Apparence', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Clair'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Sombre'),
            ),
          ],
          selected: {themeMode},
          onSelectionChanged: (selection) {
            ref.read(themeModeProvider.notifier).state = selection.first;
          },
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () async {
            await ref.read(authRepositoryProvider)?.signOut();
          },
          icon: const Icon(Icons.logout),
          label: const Text('Se déconnecter'),
        ),
      ],
    );
  }
}

/// Modification des seules coordonnées autorisées : nom d'affichage et
/// téléphone.
class _EditContactSheet extends ConsumerStatefulWidget {
  const _EditContactSheet({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_EditContactSheet> createState() => _EditContactSheetState();
}

class _EditContactSheetState extends ConsumerState<_EditContactSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.profile.displayName,
  );
  late final _phoneController = TextEditingController(
    text: widget.profile.phone ?? '',
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final phone = _phoneController.text.trim();
      await ref
          .read(authRepositoryProvider)
          ?.updateOwnContact(
            displayName: _nameController.text,
            phone: phone.isEmpty ? null : phone,
          );
      ref.invalidate(currentProfileProvider);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Coordonnées mises à jour.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Enregistrement impossible. Vérifiez la connexion.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 24,
      right: 24,
      top: 24,
      bottom: MediaQuery.of(context).viewInsets.bottom + 24,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Mes coordonnées',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _nameController,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Nom d’affichage'),
            validator: (value) {
              final length = value?.trim().length ?? 0;
              return length < 1 || length > 120
                  ? 'Saisissez entre 1 et 120 caractères.'
                  : null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phoneController,
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Téléphone'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Enregistrer'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Organisation, statut et rôles sont gérés par l’administration.',
          ),
        ],
      ),
    ),
  );
}

/// Remplacement du mot de passe initial remis par l'administrateur.
class _ChangePasswordSheet extends ConsumerStatefulWidget {
  const _ChangePasswordSheet();

  @override
  ConsumerState<_ChangePasswordSheet> createState() =>
      _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<_ChangePasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          ?.updatePassword(_passwordController.text);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Mot de passe modifié.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Modification impossible. Vérifiez la connexion ou choisissez un mot de passe plus robuste.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 24,
      right: 24,
      top: 24,
      bottom: MediaQuery.of(context).viewInsets.bottom + 24,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Nouveau mot de passe',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            enabled: !_busy,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(
              labelText: 'Nouveau mot de passe',
            ),
            validator: (value) => value == null || value.length < 10
                ? 'Utilisez au moins 10 caractères.'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _confirmController,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Confirmation'),
            validator: (value) => value != _passwordController.text
                ? 'Les deux mots de passe diffèrent.'
                : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Enregistrement…' : 'Enregistrer'),
          ),
        ],
      ),
    ),
  );
}
