/// Modèles des encaissements, lus depuis les RPC serveur `payment_summary`
/// et `payments_page` (source unique : table `payments`).
library;

int _int(Object? value) =>
    value == null ? 0 : num.parse(value.toString()).toInt();

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();

/// Totaux d'un jour du mois (paiements confirmés uniquement).
class DayTotal {
  const DayTotal({
    required this.day,
    required this.amount,
    required this.count,
  });

  factory DayTotal.fromJson(Map<String, dynamic> json) => DayTotal(
    day: DateTime.parse(json['day'] as String),
    amount: _int(json['confirmed_amount']),
    count: _int(json['confirmed_count']),
  );

  final DateTime day;
  final int amount;
  final int count;
}

/// Dernier paiement connu (tous statuts), date effective de l'encaissement.
class LastPayment {
  const LastPayment({
    required this.paidAt,
    required this.amount,
    required this.method,
    required this.status,
  });

  final DateTime? paidAt;
  final int amount;
  final String method;
  final String status;
}

/// Bilan calculé par le serveur dans le fuseau de l'organisation. Seuls les
/// paiements confirmés sont encaissés ; en attente et annulés sont à part.
class PaymentSummary {
  const PaymentSummary({
    required this.month,
    required this.todayAmount,
    required this.todayCount,
    required this.confirmedAmount,
    required this.confirmedCount,
    required this.cashAmount,
    required this.mobileMoneyAmount,
    required this.pendingAmount,
    required this.pendingCount,
    required this.cancelledAmount,
    required this.cancelledCount,
    required this.previousAmount,
    required this.previousCount,
    required this.byDay,
    required this.last,
  });

  factory PaymentSummary.fromJson(Map<String, dynamic> json) {
    final today = json['today'] as Map<String, dynamic>? ?? const {};
    final totals = json['totals'] as Map<String, dynamic>? ?? const {};
    final previous = json['previous'] as Map<String, dynamic>? ?? const {};
    final last = json['last_payment'] as Map<String, dynamic>?;
    return PaymentSummary(
      month: DateTime.parse(json['month'] as String),
      todayAmount: _int(today['confirmed_amount']),
      todayCount: _int(today['confirmed_count']),
      confirmedAmount: _int(totals['confirmed_amount']),
      confirmedCount: _int(totals['confirmed_count']),
      cashAmount: _int(totals['cash_amount']),
      mobileMoneyAmount: _int(totals['mobile_money_amount']),
      pendingAmount: _int(totals['pending_amount']),
      pendingCount: _int(totals['pending_count']),
      cancelledAmount: _int(totals['cancelled_amount']),
      cancelledCount: _int(totals['cancelled_count']),
      previousAmount: _int(previous['confirmed_amount']),
      previousCount: _int(previous['confirmed_count']),
      byDay: [
        for (final row in (json['by_day'] as List<dynamic>? ?? const []))
          DayTotal.fromJson(row as Map<String, dynamic>),
      ],
      last: last == null
          ? null
          : LastPayment(
              paidAt: _date(last['paid_at']),
              amount: _int(last['amount']),
              method: last['method'] as String? ?? '',
              status: last['status'] as String? ?? '',
            ),
    );
  }

  final DateTime month;
  final int todayAmount;
  final int todayCount;
  final int confirmedAmount;
  final int confirmedCount;
  final int cashAmount;
  final int mobileMoneyAmount;
  final int pendingAmount;
  final int pendingCount;
  final int cancelledAmount;
  final int cancelledCount;
  final int previousAmount;
  final int previousCount;
  final List<DayTotal> byDay;
  final LastPayment? last;

  /// Moyenne par paiement confirmé ; null sans paiement.
  int? get average =>
      confirmedCount == 0 ? null : (confirmedAmount / confirmedCount).round();

  /// Évolution en % par rapport au mois précédent ; null si le mois précédent est vide.
  double? get changeFromPrevious => previousAmount == 0
      ? null
      : (confirmedAmount - previousAmount) * 100 / previousAmount;
}

/// Ligne d'historique. Le nom du collecteur est absent pour un compte client.
class PaymentLine {
  const PaymentLine({
    required this.id,
    required this.paidAt,
    required this.confirmedAt,
    required this.amount,
    required this.method,
    required this.provider,
    required this.providerReference,
    required this.status,
    required this.failureReason,
    required this.establishmentName,
    required this.collectorName,
    required this.receiptNumber,
    required this.receiptStatus,
  });

  factory PaymentLine.fromRow(Map<String, dynamic> row) => PaymentLine(
    id: row['payment_id'] as String,
    paidAt: _date(row['paid_at']),
    confirmedAt: _date(row['confirmed_at']),
    amount: _int(row['amount']),
    method: row['method'] as String,
    provider: row['provider'] as String?,
    providerReference: row['provider_reference'] as String?,
    status: row['payment_status'] as String,
    failureReason: row['failure_reason'] as String?,
    establishmentName: row['establishment_name'] as String?,
    collectorName: row['collector_name'] as String?,
    receiptNumber: row['receipt_number'] as String?,
    receiptStatus: row['receipt_status'] as String?,
  );

  final String id;
  final DateTime? paidAt;
  final DateTime? confirmedAt;
  final int amount;
  final String method;
  final String? provider;
  final String? providerReference;
  final String status;
  final String? failureReason;
  final String? establishmentName;
  final String? collectorName;
  final String? receiptNumber;
  final String? receiptStatus;

  /// Référence affichée : reçu, sinon référence opérateur ; jamais un
  /// identifiant interne.
  String? get reference => receiptNumber ?? providerReference;
}

/// Page d'historique ; [total] couvre toute la sélection filtrée côté serveur.
class PaymentPage {
  const PaymentPage({required this.rows, required this.total});

  final List<PaymentLine> rows;
  final int total;
}

/// Filtre de statut accepté par `payments_page`.
enum PaymentStatusFilter {
  all(null, 'Tous'),
  confirmed('confirmed', 'Confirmés'),
  pending('pending', 'En attente'),
  cancelled('cancelled', 'Annulés');

  const PaymentStatusFilter(this.value, this.label);

  final String? value;
  final String label;
}

/// Mois disposant d'un historique (RPC `payment_months`), avec son bilan.
/// Seuls les mois réellement concernés par un paiement sont renvoyés.
class PaymentMonth {
  const PaymentMonth({
    required this.month,
    required this.confirmedAmount,
    required this.confirmedCount,
    required this.pendingAmount,
    required this.pendingCount,
    required this.cancelledCount,
  });

  factory PaymentMonth.fromRow(Map<String, dynamic> row) => PaymentMonth(
    month: DateTime.parse(row['month'] as String),
    confirmedAmount: _int(row['confirmed_amount']),
    confirmedCount: _int(row['confirmed_count']),
    pendingAmount: _int(row['pending_amount']),
    pendingCount: _int(row['pending_count']),
    cancelledCount: _int(row['cancelled_count']),
  );

  final DateTime month;
  final int confirmedAmount;
  final int confirmedCount;
  final int pendingAmount;
  final int pendingCount;
  final int cancelledCount;
}

/// Paiements d'un même jour (date effective), du plus récent au plus ancien.
class PaymentDay {
  const PaymentDay({required this.day, required this.lines});

  final DateTime day;
  final List<PaymentLine> lines;

  /// Total encaissé du jour, sur les lignes chargées (le bilan officiel du
  /// mois reste celui calculé par le serveur).
  int get confirmedAmount => lines
      .where((l) => l.status == 'confirmed')
      .fold(0, (sum, l) => sum + l.amount);
}

/// Regroupe l'historique par jour en conservant chaque paiement.
List<PaymentDay> groupByDay(List<PaymentLine> lines) {
  final days = <DateTime, List<PaymentLine>>{};
  for (final line in lines) {
    final at = line.paidAt;
    final key = at == null ? DateTime(0) : DateTime(at.year, at.month, at.day);
    days.putIfAbsent(key, () => []).add(line);
  }
  final keys = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final key in keys)
      PaymentDay(
        day: key,
        lines: days[key]!
          ..sort(
            (a, b) =>
                (b.paidAt ?? DateTime(0)).compareTo(a.paidAt ?? DateTime(0)),
          ),
      ),
  ];
}
