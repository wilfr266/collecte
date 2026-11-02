import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/live_refresh.dart';
import '../../../core/utils/currency_formatter.dart';
import '../data/payments_repository.dart';
import '../domain/payment_labels.dart';
import '../domain/payment_models.dart';
import 'client_finance_screen.dart';

/// Opérateurs Mobile Money acceptés par `record_field_payment`.
const mobileMoneyOperators = {
  'orange_money': 'Orange Money',
  'mtn_momo': 'MTN Mobile Money',
  'moov_money': 'Moov Money',
  'wave': 'Wave',
  'other': 'Autre opérateur',
};

String formatDateTime(Object? value) {
  final date = DateTime.tryParse(value as String? ?? '')?.toLocal();
  if (date == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} à ${two(date.hour)}h${two(date.minute)}';
}

const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

String monthLabel(DateTime month) =>
    '${_months[month.month - 1]} ${month.year}';

const _weekdays = [
  'Lundi',
  'Mardi',
  'Mercredi',
  'Jeudi',
  'Vendredi',
  'Samedi',
  'Dimanche',
];

/// « Mardi 28 octobre 2026 » (date effective, heure locale de l'appareil).
String dayLabel(DateTime day) =>
    '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]} ${day.year}';

/// « 16 h 30 ».
String timeLabel(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')} h ${at.minute.toString().padLeft(2, '0')}';

/// Synthèse compacte calculée par le serveur (aujourd'hui, mois en cours,
/// dernier paiement) et accès à la fiche financière complète.
class TaxpayerPaymentsPanel extends ConsumerStatefulWidget {
  const TaxpayerPaymentsPanel({
    super.key,
    required this.taxpayerId,
    required this.establishments,
    this.title = 'Fiche financière',
    this.details = const [],
    this.canRecord = false,
    this.organizationId,
  });

  final String taxpayerId;

  /// Établissements actifs du client (`id`, `name`) : lieux d'encaissement.
  final List<Map<String, dynamic>> establishments;
  final String title;
  final List<String> details;
  final bool canRecord;
  final String? organizationId;

  @override
  ConsumerState<TaxpayerPaymentsPanel> createState() =>
      _TaxpayerPaymentsPanelState();
}

class _TaxpayerPaymentsPanelState extends ConsumerState<TaxpayerPaymentsPanel> {
  Future<PaymentSummary>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final repository = ref.read(paymentsRepositoryProvider);
    final now = DateTime.now();
    setState(() {
      _summary = repository?.summary(
        taxpayerId: widget.taxpayerId,
        month: DateTime(now.year, now.month),
      );
    });
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClientFinanceScreen(
          taxpayerId: widget.taxpayerId,
          title: widget.title,
          details: widget.details,
          establishments: widget.establishments,
          canRecord: widget.canRecord,
          organizationId: widget.organizationId,
        ),
      ),
    );
    // Retour de la fiche : la synthèse reflète les encaissements faits entre-temps.
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final organizationId = widget.organizationId;
    final card = _card(context);
    if (organizationId == null) return card;
    // Mise à jour dès qu'un paiement est enregistré ou confirmé.
    return LiveRefresh(
      channel: 'payments-panel-${widget.taxpayerId}',
      sources: [
        for (final table in ['payments', 'financial_obligations'])
          LiveSource(
            table,
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'organization_id',
              value: organizationId,
            ),
          ),
      ],
      onRefresh: _load,
      child: card,
    );
  }

  Widget _card(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<PaymentSummary>(
            future: _summary,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done &&
                  !snapshot.hasData) {
                return const LinearProgressIndicator();
              }
              final s = snapshot.data;
              if (snapshot.hasError || s == null) {
                return Row(
                  children: [
                    const Expanded(child: Text('Bilan indisponible.')),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Réessayer'),
                    ),
                  ],
                );
              }
              final last = s.last;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Aujourd’hui : ${CurrencyFormatter.formatCfa(s.todayAmount)} (${s.todayCount})',
                  ),
                  Text(
                    '${monthLabel(s.month)} : ${CurrencyFormatter.formatCfa(s.confirmedAmount)} · ${s.confirmedCount} paiement(s) confirmé(s)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (s.pendingCount > 0)
                    Text(
                      'En attente : ${CurrencyFormatter.formatCfa(s.pendingAmount)} (${s.pendingCount}) — non encaissé',
                    ),
                  Text(
                    last == null
                        ? 'Aucun paiement enregistré.'
                        : 'Dernier : ${CurrencyFormatter.formatCfa(last.amount)} le ${formatDateTime(last.paidAt?.toIso8601String())} · ${paymentStatusLabel(last.status, method: last.method)}',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _open,
            icon: const Icon(Icons.receipt_long),
            label: Text(
              widget.canRecord
                  ? 'Historique, bilan et encaissement'
                  : 'Historique et bilan mensuel',
            ),
          ),
        ],
      ),
    ),
  );
}

/// Saisie d'un encaissement. La clé d'idempotence est fixée à l'ouverture :
/// une nouvelle tentative (réseau coupé, double appui) ne crée pas de doublon.
class RecordPaymentDialog extends ConsumerStatefulWidget {
  const RecordPaymentDialog({super.key, required this.establishments});

  final List<Map<String, dynamic>> establishments;

  @override
  ConsumerState<RecordPaymentDialog> createState() =>
      _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends ConsumerState<RecordPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _idempotencyKey = const Uuid().v4();
  late String _establishmentId = widget.establishments.first['id'] as String;
  String _method = 'cash';
  String _operator = 'orange_money';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    final repository = ref.read(paymentsRepositoryProvider);
    if (repository == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await repository.record(
        establishmentId: _establishmentId,
        amount: int.parse(_amount.text.replaceAll(RegExp(r'\s'), '')),
        method: _method,
        idempotencyKey: _idempotencyKey,
        provider: _operator,
        providerReference: _reference.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        result.status == 'confirmed'
            ? 'Paiement confirmé · reçu ${result.receiptNumber}'
            : 'Paiement Mobile Money enregistré : en attente de vérification par l’organisation.',
      );
    } on PostgrestException catch (error) {
      setState(
        () => _error = switch (error.code) {
          '23505' =>
            error.message.contains('reference')
                ? 'Cette référence Mobile Money a déjà été enregistrée.'
                : 'Un paiement identique vient d’être enregistré.',
          '42501' => 'Ce client n’est pas dans une de vos missions actives.',
          '22023' => 'Montant ou informations invalides.',
          _ => 'Enregistrement impossible. Réessayez.',
        },
      );
    } catch (_) {
      setState(
        () => _error =
            'Réseau indisponible. Réessayez : le paiement ne sera pas compté deux fois.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Enregistrer un paiement'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.establishments.length > 1)
              DropdownButtonFormField<String>(
                initialValue: _establishmentId,
                decoration: const InputDecoration(labelText: 'Établissement'),
                items: [
                  for (final e in widget.establishments)
                    DropdownMenuItem(
                      value: e['id'] as String,
                      child: Text(e['name'] as String),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _establishmentId = value!),
              ),
            TextFormField(
              controller: _amount,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant (FCFA)'),
              validator: (value) {
                final amount = int.tryParse(
                  (value ?? '').replaceAll(RegExp(r'\s'), ''),
                );
                return amount == null || amount <= 0
                    ? 'Montant invalide.'
                    : null;
              },
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'cash',
                  label: Text('Espèces'),
                  icon: Icon(Icons.payments_outlined),
                ),
                ButtonSegment(
                  value: 'mobile_money',
                  label: Text('Mobile Money'),
                  icon: Icon(Icons.phone_android),
                ),
              ],
              selected: {_method},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() => _method = selection.first),
            ),
            if (_method == 'mobile_money') ...[
              DropdownButtonFormField<String>(
                initialValue: _operator,
                decoration: const InputDecoration(labelText: 'Opérateur'),
                items: [
                  for (final entry in mobileMoneyOperators.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _operator = value!),
              ),
              TextFormField(
                controller: _reference,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Référence de la transaction',
                ),
                validator: (value) {
                  final length = (value ?? '').trim().length;
                  return length < 4 || length > 80
                      ? 'Référence requise (4 à 80 caractères).'
                      : null;
                },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Le paiement restera en attente jusqu’à sa vérification par l’organisation.',
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Espèces reçues : le paiement est confirmé et un reçu est émis immédiatement.',
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? 'Enregistrement…' : 'Enregistrer'),
      ),
    ],
  );
}
