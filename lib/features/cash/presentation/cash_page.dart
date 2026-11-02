import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../auth/presentation/auth_providers.dart';

class CashPage extends ConsumerStatefulWidget {
  const CashPage({super.key});

  @override
  ConsumerState<CashPage> createState() => _CashPageState();
}

class _CashPageState extends ConsumerState<CashPage> {
  List<Map<String, dynamic>> _registers = [];
  List<Map<String, dynamic>> _reconciliations = [];
  List<Map<String, dynamic>> _movements = [];
  Map<String, dynamic>? _summary;
  String? _registerId;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final _countController = TextEditingController();
  final _reasonController = TextEditingController();
  late String _idempotencyKey = _newKey();

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _countController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = ref.read(supabaseClientProvider);
    final profile = await ref.read(currentProfileProvider.future);
    if (client == null || profile?.organizationId == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Session de caisse indisponible.';
        });
      }
      return;
    }
    try {
      final registers = await client
          .from('cash_registers')
          .select('id, code, label, status, opened_at, closed_at')
          .eq('organization_id', profile!.organizationId!)
          .eq('assigned_cashier_id', profile.id)
          .order('code');
      if (registers.isEmpty) {
        if (mounted) {
          setState(() {
            _registers = [];
            _loading = false;
          });
        }
        return;
      }
      final selectedId =
          _registerId != null &&
              registers.any((row) => row['id'] == _registerId)
          ? _registerId!
          : registers.first['id'] as String;
      final summaryRows =
          await client.rpc(
                'cash_register_summary',
                params: {'p_cash_register_id': selectedId},
              )
              as List<dynamic>;
      final reconciliations = await client
          .from('cash_reconciliations')
          .select(
            'id, expected_amount, counted_amount, difference_amount, status, notes, created_at',
          )
          .eq('organization_id', profile.organizationId!)
          .eq('cash_register_id', selectedId)
          .order('created_at', ascending: false)
          .limit(20);
      final movements = await client
          .from('cash_movements')
          .select('id, movement_type, amount, direction, reference, created_at')
          .eq('organization_id', profile.organizationId!)
          .eq('cash_register_id', selectedId)
          .order('created_at', ascending: false)
          .limit(50);
      if (mounted) {
        setState(() {
          _registers = registers;
          _registerId = selectedId;
          _summary = summaryRows.isEmpty
              ? null
              : Map<String, dynamic>.from(summaryRows.first as Map);
          _reconciliations = reconciliations;
          _movements = movements;
          _loading = false;
        });
      }
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.code == '42501'
              ? 'Accès réservé au caissier affecté à une caisse.'
              : 'Données de caisse indisponibles.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Réseau indisponible. Réessayez.';
        });
      }
    }
  }

  Future<void> _submitReconciliation() async {
    final amount = int.tryParse(_countController.text.trim());
    if (amount == null || amount < 0 || _registerId == null) {
      setState(() => _error = 'Saisissez un solde réel valide en FCFA.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(supabaseClientProvider)!
          .rpc(
            'submit_cash_reconciliation',
            params: {
              'p_cash_register_id': _registerId,
              'p_counted_amount': amount,
              'p_idempotency_key': _idempotencyKey,
              'p_notes': _reasonController.text.trim().isEmpty
                  ? null
                  : _reasonController.text.trim(),
            },
          );
      _countController.clear();
      _reasonController.clear();
      _idempotencyKey = _newKey();
      await _load();
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.code == '42501'
              ? 'Cette opération est réservée à un caissier autorisé.'
              : 'Le rapprochement n’a pas pu être enregistré. Indiquez un motif en cas d’écart puis réessayez.',
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Réseau indisponible. Réessayez avec la même saisie.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _newKey() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Caisse'),
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _registers.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
          )
        : _registers.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Aucune caisse ne vous est affectée.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<String>(
                initialValue: _registerId,
                decoration: const InputDecoration(labelText: 'Caisse affectée'),
                items: _registers
                    .map(
                      (row) => DropdownMenuItem(
                        value: row['id'] as String,
                        child: Text('${row['code']} · ${row['label']}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setState(() => _registerId = value);
                  _load();
                },
              ),
              const SizedBox(height: 16),
              if (_summary != null) ...[
                _CashMetric(
                  label: 'Solde d’ouverture',
                  value: _summary!['opening_balance'],
                ),
                _CashMetric(
                  label: 'Encaissements',
                  value: _summary!['collections_total'],
                ),
                _CashMetric(
                  label: 'Remises et sorties',
                  value: _summary!['disbursements_total'],
                ),
                _CashMetric(
                  label: 'Ajustements nets',
                  value: _summary!['adjustments_net'],
                ),
                _CashMetric(
                  label: 'Solde théorique',
                  value: _summary!['theoretical_balance'],
                  highlight: true,
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Déclarer le solde réel',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _countController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: false,
                ),
                decoration: const InputDecoration(
                  labelText: 'Solde compté (FCFA)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Justification de l’écart, si nécessaire',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _submitReconciliation,
                child: Text(
                  _busy ? 'Transmission…' : 'Soumettre le rapprochement',
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Mouvements récents',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (_movements.isEmpty)
                const ListTile(title: Text('Aucun mouvement de caisse.'))
              else
                for (final movement in _movements)
                  ListTile(
                    title: Text(
                      _movementLabel(movement['movement_type'] as String),
                    ),
                    subtitle: Text(movement['reference'] as String? ?? ''),
                    trailing: Text(
                      '${(movement['direction'] as num).toInt() < 0 ? '−' : '+'}${CurrencyFormatter.formatCfa((movement['amount'] as num).toInt())}',
                    ),
                  ),
              const SizedBox(height: 24),
              Text('Historique', style: Theme.of(context).textTheme.titleLarge),
              for (final item in _reconciliations)
                ListTile(
                  title: Text(
                    'Écart · ${CurrencyFormatter.formatCfa((item['difference_amount'] as num).toInt())}',
                  ),
                  subtitle: Text(
                    '${item['status']} · ${item['notes'] ?? 'Sans note'}',
                  ),
                ),
            ],
          ),
  );
}

class _CashMetric extends StatelessWidget {
  const _CashMetric({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final Object? value;
  final bool highlight;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    trailing: Text(
      CurrencyFormatter.formatCfa((value as num?)?.toInt() ?? 0),
      style: highlight ? Theme.of(context).textTheme.titleMedium : null,
    ),
  );
}

String _movementLabel(String value) => switch (value) {
  'opening' => 'Ouverture',
  'collection' => 'Encaissement',
  'disbursement' => 'Remise / sortie',
  'reversal' => 'Annulation compensatoire',
  _ => 'Ajustement',
};
