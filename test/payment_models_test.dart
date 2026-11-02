import 'package:flutter_test/flutter_test.dart';
import 'package:terenza/features/payments/domain/payment_models.dart';
import 'package:terenza/features/payments/presentation/taxpayer_payments_panel.dart';

void main() {
  final json = {
    'timezone': 'Africa/Abidjan',
    'month': '2026-10-01',
    'today': {
      'date': '2026-10-27',
      'confirmed_amount': 2500,
      'confirmed_count': 1,
    },
    'totals': {
      'confirmed_amount': 3500,
      'confirmed_count': 2,
      'cash_amount': 2500,
      'mobile_money_amount': '1000',
      'pending_amount': 4000,
      'pending_count': 1,
      'cancelled_amount': 700,
      'cancelled_count': 1,
      'clients_paid': 1,
    },
    'previous': {
      'month': '2026-09-01',
      'confirmed_amount': 2800,
      'confirmed_count': 4,
    },
    'by_day': [
      {'day': '2026-10-26', 'confirmed_amount': 1000, 'confirmed_count': 1},
      {'day': '2026-10-27', 'confirmed_amount': 2500, 'confirmed_count': 1},
    ],
    'last_payment': {
      'paid_at': '2026-10-27T09:05:00+00:00',
      'amount': 4000,
      'method': 'mobile_money',
      'status': 'pending',
    },
  };

  test(
    'le bilan serveur est lu tel quel : encaissé, en attente et annulé séparés',
    () {
      final s = PaymentSummary.fromJson(json);
      expect(s.confirmedAmount, 3500);
      expect(s.mobileMoneyAmount, 1000);
      expect(s.pendingAmount, 4000);
      expect(s.cancelledAmount, 700);
      expect(s.todayAmount, 2500);
      expect(s.byDay.map((d) => d.amount), [1000, 2500]);
      expect(s.last?.status, 'pending');
    },
  );

  test('moyenne et évolution par rapport au mois précédent', () {
    final s = PaymentSummary.fromJson(json);
    expect(s.average, 1750);
    expect(s.changeFromPrevious!.round(), 25);
  });

  test(
    'un client sans paiement : aucun total inventé, pas de moyenne ni d’évolution',
    () {
      final s = PaymentSummary.fromJson({
        'month': '2026-10-01',
        'by_day': [],
        'last_payment': null,
      });
      expect(s.confirmedAmount, 0);
      expect(s.average, isNull);
      expect(s.changeFromPrevious, isNull);
      expect(s.last, isNull);
    },
  );

  test(
    'référence affichée : reçu, sinon référence opérateur, jamais l’identifiant interne',
    () {
      PaymentLine line(String? receipt, String? reference) =>
          PaymentLine.fromRow({
            'payment_id': '0b5c1a2e-1234-4cde-9abc-0123456789ab',
            'paid_at': '2026-10-27T09:05:00+00:00',
            'amount': '2500',
            'method': 'cash',
            'payment_status': 'confirmed',
            'receipt_number': receipt,
            'provider_reference': reference,
          });
      expect(line('R-2026-00000001', 'OM1').reference, 'R-2026-00000001');
      expect(line(null, 'OM123456').reference, 'OM123456');
      // Jamais d'identifiant interne à l'écran : aucune référence affichée.
      expect(line(null, null).reference, isNull);
      expect(line(null, null).amount, 2500);
    },
  );

  test('formatDateTime affiche la date et l’heure locales', () {
    final local = DateTime(2026, 10, 27, 9, 5);
    expect(
      formatDateTime(local.toUtc().toIso8601String()),
      '27/10/2026 à 09h05',
    );
    expect(formatDateTime(null), '—');
  });
}
