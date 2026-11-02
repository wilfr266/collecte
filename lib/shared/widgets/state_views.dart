import 'package:flutter/material.dart';

/// Message centré (état vide ou erreur récupérable), lisible sur petit écran.
///
/// Placé dans une liste défilante pour rester compatible avec
/// `RefreshIndicator` (« tirer pour actualiser »).
class StateMessageView extends StatelessWidget {
  const StateMessageView({
    required this.icon,
    required this.message,
    this.onRetry,
    super.key,
  });

  /// Erreur réseau ou d'accès avec bouton « Réessayer ».
  const StateMessageView.error({
    required this.message,
    required this.onRetry,
    super.key,
  }) : icon = Icons.cloud_off_outlined;

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Réessayer'),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
