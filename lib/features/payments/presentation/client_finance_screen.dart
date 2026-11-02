import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/live_refresh.dart';
import '../../../core/utils/currency_formatter.dart';
import '../data/payments_repository.dart';
import '../domain/payment_labels.dart';
import '../domain/payment_models.dart';
import 'taxpayer_payments_panel.dart';

/// Fiche financière d'un client : synthèse (jour, mois, dernier paiement),
/// bilan mensuel calculé par le serveur, historique paginé et filtré, et
/// encaissement pour le collecteur affecté ([canRecord]).
class ClientFinanceScreen extends ConsumerStatefulWidget {
  const ClientFinanceScreen({
    super.key,
    required this.taxpayerId,
    required this.title,
    this.details = const [],
    this.establishments = const [],
    this.canRecord = false,
    this.organizationId,
    this.initialMonth,
    this.highlightPaymentId,
  });

  final String taxpayerId;
  final String title;

  /// Informations du client déjà disponibles (identifiant, téléphone…).
  final List<String> details;

  /// Établissements actifs (`id`, `name`) : lieux d'encaissement possibles.
  final List<Map<String, dynamic>> establishments;
  final bool canRecord;
  final String? organizationId;

  /// Mois affiché à l'ouverture (ex. paiement ouvert depuis une notification).
  final DateTime? initialMonth;

  /// Paiement mis en évidence dans l'historique.
  final String? highlightPaymentId;

  @override
  ConsumerState<ClientFinanceScreen> createState() =>
      _ClientFinanceScreenState();
}

class _ClientFinanceScreenState extends ConsumerState<ClientFinanceScreen> {
  static const _pageSize = 30;

  late DateTime _month;
  late final DateTime _currentMonth;
  PaymentStatusFilter _status = PaymentStatusFilter.all;
  final _search = TextEditingController();
  Timer? _debounce;

  PaymentSummary? _summary;
  Object? _summaryError;
  List<PaymentMonth> _months = const [];
  final List<PaymentLine> _rows = [];
  int _total = 0;
  bool _loadingPage = false;
  Object? _pageError;
  DateTime? _updatedAt;

  // Chaque rechargement porte un numéro : une réponse ancienne ne remplace pas une plus récente.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month);
    final initial = widget.initialMonth;
    _month = initial == null
        ? _currentMonth
        : DateTime(initial.year, initial.month);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  PaymentsRepository? get _repository => ref.read(paymentsRepositoryProvider);

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _summaryError = null;
      _pageError = null;
    });
    await Future.wait([
      _loadMonths(),
      _loadSummary(generation),
      _loadPage(generation, reset: true),
    ]);
    if (mounted && generation == _generation) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  /// Mois disposant d'un historique : alimente le sélecteur. Un échec
  /// n'empêche pas l'affichage du mois courant.
  Future<void> _loadMonths() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final months = await repository.months(taxpayerId: widget.taxpayerId);
      if (mounted) setState(() => _months = months);
    } catch (_) {
      // Le sélecteur conserve les mois déjà connus.
    }
  }

  Future<void> _loadSummary(int generation) async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final summary = await repository.summary(
        taxpayerId: widget.taxpayerId,
        month: _month,
      );
      if (mounted && generation == _generation) {
        setState(() => _summary = summary);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _summaryError = error);
      }
    }
  }

  Future<void> _loadPage(int generation, {required bool reset}) async {
    final repository = _repository;
    if (repository == null || _loadingPage && !reset) return;
    setState(() => _loadingPage = true);
    try {
      final page = await repository.page(
        taxpayerId: widget.taxpayerId,
        from: _month,
        to: DateTime(_month.year, _month.month + 1, 0),
        status: _status,
        search: _search.text,
        limit: _pageSize,
        offset: reset ? 0 : _rows.length,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(page.rows);
        _total = page.total;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _pageError = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingPage = false);
      }
    }
  }

  void _setMonth(DateTime month) {
    _month = month;
    _summary = null;
    _reload();
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _loadPage(++_generation, reset: true),
    );
  }

  Future<void> _record() async {
    final message = await showDialog<String>(
      context: context,
      builder: (context) =>
          RecordPaymentDialog(establishments: widget.establishments),
    );
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    // Le paiement est relu depuis le serveur : affichage de l'état réel enregistré.
    _month = _currentMonth;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final body = RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          for (final line in widget.details) Text(line),
          if (widget.details.isNotEmpty) const SizedBox(height: 12),
          _SummaryCards(
            summary: _summary,
            error: _summaryError,
            onRetry: _reload,
          ),
          const SizedBox(height: 12),
          _MonthSelector(
            month: _month,
            currentMonth: _currentMonth,
            months: _months,
            onChanged: _setMonth,
          ),
          if (_summary != null) _MonthlyReport(summary: _summary!),
          const SizedBox(height: 16),
          Text('Historique', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            onChanged: _onSearch,
            decoration: const InputDecoration(
              labelText: 'Rechercher une référence (reçu, opérateur)',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final filter in PaymentStatusFilter.values)
                ChoiceChip(
                  label: Text(filter.label),
                  selected: _status == filter,
                  onSelected: (_) {
                    setState(() => _status = filter);
                    _loadPage(++_generation, reset: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_pageError != null)
            _ErrorBox(
              message:
                  'L’historique n’a pas pu être chargé. Vérifiez votre connexion puis réessayez.',
              onRetry: _reload,
            )
          else if (_rows.isEmpty && _loadingPage)
            const LinearProgressIndicator()
          else if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Aucun paiement en ${monthLabel(_month).toLowerCase()}'
                '${_status == PaymentStatusFilter.all && _search.text.isEmpty ? '' : ' pour ces filtres'}.',
              ),
            )
          else ...[
            Text(
              '${_rows.length} sur $_total paiement(s)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            for (final day in groupByDay(_rows)) ...[
              _DayHeader(day: day),
              for (final line in day.lines)
                PaymentLineTile(
                  line: line,
                  highlighted: line.id == widget.highlightPaymentId,
                ),
            ],
            if (_rows.length < _total)
              Center(
                child: TextButton(
                  onPressed: _loadingPage
                      ? null
                      : () => _loadPage(_generation, reset: false),
                  child: Text(_loadingPage ? 'Chargement…' : 'Charger plus'),
                ),
              ),
          ],
          if (_summary != null) _MonthEndTotal(summary: _summary!),
          if (_updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Actualisé à ${formatDateTime(_updatedAt!.toIso8601String()).split(' à ').last}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );

    final organizationId = widget.organizationId;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: widget.canRecord && widget.establishments.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _record,
              icon: const Icon(Icons.add_card),
              label: const Text('Encaisser'),
            )
          : null,
      // Mise à jour en direct sur tout changement de paiement de l'organisation
      // (RLS appliquée) ; actualisation périodique et au retour réseau sinon.
      body: organizationId == null
          ? body
          : LiveRefresh(
              channel: 'client-finance-${widget.taxpayerId}',
              sources: [
                // Collecteur et administration : lecture directe des paiements.
                LiveSource(
                  'payments',
                  filter: PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'organization_id',
                    value: organizationId,
                  ),
                ),
                // Client : les paiements lui sont fermés (RLS) ; la confirmation met
                // à jour l'obligation de son établissement, qu'il peut lire.
                LiveSource(
                  'financial_obligations',
                  filter: PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'organization_id',
                    value: organizationId,
                  ),
                ),
              ],
              onRefresh: _reload,
              child: body,
            ),
    );
  }
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({
    required this.summary,
    required this.error,
    required this.onRetry,
  });

  final PaymentSummary? summary;
  final Object? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return _ErrorBox(message: 'Bilan indisponible.', onRetry: onRetry);
    }
    final s = summary;
    if (s == null) return const LinearProgressIndicator();
    final last = s.last;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.9,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        _Kpi(
          label: 'Aujourd’hui',
          value: CurrencyFormatter.formatCfa(s.todayAmount),
          hint: '${s.todayCount} paiement(s)',
        ),
        _Kpi(
          label: 'Ce mois-ci',
          value: CurrencyFormatter.formatCfa(s.confirmedAmount),
          hint: 'Confirmé',
        ),
        _Kpi(
          label: 'Paiements confirmés',
          value: '${s.confirmedCount}',
          hint: monthLabel(s.month),
        ),
        _Kpi(
          label: 'Dernier paiement',
          value: last == null ? '—' : CurrencyFormatter.formatCfa(last.amount),
          hint: last == null
              ? 'Aucun paiement'
              : '${formatDateTime(last.paidAt?.toIso8601String())} · ${paymentStatusLabel(last.status, method: last.method)}',
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.hint});

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          FittedBox(
            child: Text(value, style: Theme.of(context).textTheme.titleMedium),
          ),
          Text(
            hint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

/// Menu déroulant des mois ayant un historique, avec le total encaissé de
/// chacun. Le mois courant reste proposé même sans paiement (période en cours).
class _MonthSelector extends StatelessWidget {
  const _MonthSelector({
    required this.month,
    required this.currentMonth,
    required this.months,
    required this.onChanged,
  });

  final DateTime month;
  final DateTime currentMonth;
  final List<PaymentMonth> months;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final byMonth = {for (final m in months) m.month: m};
    final options = <DateTime>{currentMonth, month, ...byMonth.keys}.toList()
      ..sort((a, b) => b.compareTo(a));
    String label(DateTime value) {
      final data = byMonth[value];
      final name = monthLabel(value);
      final title = '${name[0].toUpperCase()}${name.substring(1)}';
      if (data == null) return '$title — aucun paiement';
      return '$title — ${CurrencyFormatter.formatCfa(data.confirmedAmount)}';
    }

    return DropdownButtonFormField<DateTime>(
      key: ValueKey(month),
      initialValue: month,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Mois',
        prefixIcon: Icon(Icons.calendar_month_outlined),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(label(option), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        if (value != null && value != month) onChanged(value);
      },
    );
  }
}

/// En-tête d'une journée : date complète et total encaissé du jour.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final PaymentDay day;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            dayLabel(day.day),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Text(
          '${CurrencyFormatter.formatCfa(day.confirmedAmount)} · ${day.lines.length} paiement(s)',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

/// Bilan final du mois sélectionné, calculé par le serveur sur tous les
/// paiements du mois (et non sur les seules lignes affichées).
class _MonthEndTotal extends StatelessWidget {
  const _MonthEndTotal({required this.summary});

  final PaymentSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 16),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Total payé pendant ${monthLabel(s.month).toLowerCase()}',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              CurrencyFormatter.formatCfa(s.confirmedAmount),
              style: theme.textTheme.headlineSmall,
            ),
            Text('${s.confirmedCount} paiement(s) confirmé(s)'),
            if (s.pendingCount > 0)
              Text(
                'En attente : ${CurrencyFormatter.formatCfa(s.pendingAmount)} (${s.pendingCount}) — non compris dans le total',
              ),
            if (s.cancelledCount > 0)
              Text(
                'Annulés ou refusés : ${s.cancelledCount} — non compris dans le total',
              ),
          ],
        ),
      ),
    );
  }
}

class _MonthlyReport extends StatelessWidget {
  const _MonthlyReport({required this.summary});

  final PaymentSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final change = s.changeFromPrevious;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Encaissé : ${CurrencyFormatter.formatCfa(s.confirmedAmount)} (${s.confirmedCount} paiement(s))',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              'Espèces ${CurrencyFormatter.formatCfa(s.cashAmount)} · Mobile Money ${CurrencyFormatter.formatCfa(s.mobileMoneyAmount)}',
            ),
            if (s.average != null)
              Text(
                'Moyenne par paiement : ${CurrencyFormatter.formatCfa(s.average!)}',
              ),
            Text(
              'Mois précédent : ${CurrencyFormatter.formatCfa(s.previousAmount)}'
              '${change == null ? '' : ' (${change >= 0 ? '+' : ''}${change.toStringAsFixed(0)} %)'}',
            ),
            if (s.pendingCount > 0)
              Text(
                'En attente de vérification : ${CurrencyFormatter.formatCfa(s.pendingAmount)} (${s.pendingCount}) — non encaissé',
              ),
            if (s.cancelledCount > 0)
              Text(
                'Annulés ou refusés : ${CurrencyFormatter.formatCfa(s.cancelledAmount)} (${s.cancelledCount}) — non encaissé',
              ),
            if (s.byDay.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Répartition par jour'),
                children: [
                  for (final day in s.byDay)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${day.day.day.toString().padLeft(2, '0')}/${day.day.month.toString().padLeft(2, '0')}',
                      ),
                      trailing: Text(
                        '${CurrencyFormatter.formatCfa(day.amount)} (${day.count})',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'historique : heure effective, montant, mode, référence, statut.
class PaymentLineTile extends StatelessWidget {
  const PaymentLineTile({
    super.key,
    required this.line,
    this.highlighted = false,
  });

  final PaymentLine line;

  /// Paiement ouvert depuis une notification.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final at = line.paidAt;
    final reference = line.reference;
    return Card(
      shape: highlighted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: ListTile(
        leading: Icon(
          line.method == 'cash' ? Icons.payments_outlined : Icons.phone_android,
        ),
        title: Text(
          '${at == null ? '' : '${timeLabel(at)} — '}${CurrencyFormatter.formatCfa(line.amount)}',
        ),
        subtitle: Text(
          [
            paymentMethodLabel(line.method),
            if (reference != null)
              'Réf. $reference${line.receiptStatus == 'voided' ? ' (reçu annulé)' : ''}',
            if (line.provider != null)
              mobileMoneyOperators[line.provider] ?? line.provider!,
            if (line.providerReference != null && line.receiptNumber != null)
              'Transaction ${line.providerReference}',
            if (line.establishmentName != null) line.establishmentName!,
            if (line.collectorName != null)
              'Encaissé par ${line.collectorName}',
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: Chip(
          label: Text(
            paymentStatusLabel(
              line.status,
              method: line.method,
              failureReason: line.failureReason,
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(child: Text(message)),
        TextButton(onPressed: onRetry, child: const Text('Réessayer')),
      ],
    ),
  );
}
