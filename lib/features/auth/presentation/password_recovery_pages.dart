import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';

class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          ?.sendPasswordReset(_emailController.text);
      setState(() => _sent = true);
    } on AuthException {
      setState(
        () => _error = 'Impossible d’envoyer l’e-mail. Vérifiez votre adresse.',
      );
    } catch (_) {
      setState(
        () => _error =
            'Service indisponible. Réessayez lorsque le réseau revient.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Récupération du compte')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _sent
                ? 'Si cette adresse correspond à un compte, un lien de réinitialisation a été envoyé.'
                : 'Saisissez l’adresse e-mail associée à votre compte.',
          ),
          if (!_sent) ...[
            const SizedBox(height: 20),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Adresse e-mail'),
                validator: (value) => value == null || !value.contains('@')
                    ? 'Saisissez une adresse e-mail valide.'
                    : null,
              ),
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
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Envoi…' : 'Envoyer le lien'),
            ),
          ],
          TextButton(
            onPressed: () => context.go('/auth'),
            child: const Text('Retour à la connexion'),
          ),
        ],
      ),
    ),
  );
}

class ResetPasswordPage extends ConsumerStatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  ConsumerState<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends ConsumerState<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          ?.updatePassword(_passwordController.text);
      ref.read(passwordRecoveryProvider.notifier).complete();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Mot de passe modifié.')));
      context.go('/auth');
    } on AuthException {
      setState(
        () => _error =
            'Le lien a expiré ou ne permet plus de modifier le mot de passe.',
      );
    } catch (_) {
      setState(
        () => _error = 'Modification impossible. Vérifiez votre connexion.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nouveau mot de passe')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Form(
            key: _formKey,
            child: TextFormField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Nouveau mot de passe',
              ),
              validator: (value) => value == null || value.length < 8
                  ? 'Utilisez au moins 8 caractères.'
                  : null,
            ),
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
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Enregistrement…' : 'Enregistrer'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => ref.read(authRepositoryProvider)?.signOut(),
            child: const Text('Annuler et se déconnecter'),
          ),
        ],
      ),
    ),
  );
}
