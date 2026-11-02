import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/features/notifications/data/notifications_repository.dart';
import 'package:terenza/features/payments/domain/payment_models.dart';
import 'package:terenza/features/payments/presentation/taxpayer_payments_panel.dart';

PaymentLine _line(
  String id,
  DateTime paidAt,
  int amount, {
  String status = 'confirmed',
}) => PaymentLine.fromRow({
  'payment_id': id,
  'paid_at': paidAt.toUtc().toIso8601String(),
  'confirmed_at': null,
  'amount': amount,
  'method': 'cash',
  'payment_status': status,
});

AppNotification _notification(
  String id,
  DateTime createdAt, {
  bool read = false,
}) => AppNotification(
  id: id,
  title: 'Paiement confirmé',
  body: 'Votre paiement de 5 000 FCFA a été confirmé.',
  createdAt: createdAt,
  readAt: read ? createdAt : null,
  paymentId: 'pay-$id',
);

void main() {
  group('historique jour par jour', () {
    test('plusieurs paiements le même jour restent distincts et triés', () {
      final days = groupByDay([
        _line('a', DateTime(2026, 10, 27, 11, 15), 2000),
        _line('b', DateTime(2026, 10, 28, 9, 45), 3000),
        _line('c', DateTime(2026, 10, 28, 16, 30), 5000),
      ]);
      expect(days.map((d) => d.day), [
        DateTime(2026, 10, 28),
        DateTime(2026, 10, 27),
      ]);
      expect(days.first.lines.map((l) => l.id), ['c', 'b']);
      expect(days.first.confirmedAmount, 8000);
    });

    test(
      'un paiement en attente ou annulé n’entre pas dans le total du jour',
      () {
        final day = groupByDay([
          _line('a', DateTime(2026, 10, 28, 9), 5000),
          _line('b', DateTime(2026, 10, 28, 10), 1000, status: 'pending'),
          _line('c', DateTime(2026, 10, 28, 11), 700, status: 'reversed'),
        ]).single;
        expect(day.lines, hasLength(3));
        expect(day.confirmedAmount, 5000);
      },
    );

    test('la référence n’expose jamais l’identifiant interne', () {
      expect(_line('8f2c1a90-x', DateTime(2026, 10, 28), 1).reference, isNull);
    });

    test('libellés de jour et d’heure', () {
      expect(dayLabel(DateTime(2026, 10, 28)), 'Mercredi 28 octobre 2026');
      expect(timeLabel(DateTime(2026, 10, 28, 16, 30)), '16 h 30');
    });
  });

  group('mois disponibles', () {
    test('lecture du bilan mensuel renvoyé par le serveur', () {
      final month = PaymentMonth.fromRow({
        'month': '2026-10-01',
        'confirmed_amount': '25000',
        'confirmed_count': 4,
        'pending_amount': 1000,
        'pending_count': 1,
        'cancelled_count': 0,
      });
      expect(month.month, DateTime(2026, 10));
      expect(month.confirmedAmount, 25000);
      expect(month.pendingCount, 1);
    });
  });

  group('alertes de notification', () {
    final lastAlerted = DateTime.utc(2026, 10, 28, 10);

    test(
      'seules les nouvelles notifications non lues déclenchent une alerte',
      () {
        final alerts = selectNewAlerts([
          _notification('old', DateTime.utc(2026, 10, 28, 9)),
          _notification('read', DateTime.utc(2026, 10, 28, 11), read: true),
          _notification('new', DateTime.utc(2026, 10, 28, 12)),
        ], lastAlerted);
        expect(alerts.map((n) => n.id), ['new']);
      },
    );

    test('une relance ne rejoue pas une alerte déjà faite', () {
      final notifications = [
        _notification('n', DateTime.utc(2026, 10, 28, 12)),
      ];
      final first = selectNewAlerts(notifications, lastAlerted);
      expect(first, hasLength(1));
      expect(selectNewAlerts(notifications, first.first.createdAt), isEmpty);
    });

    test('pas de rafale de vibrations', () {
      final many = [
        for (var i = 0; i < 10; i++)
          _notification('n$i', DateTime.utc(2026, 10, 28, 12, i)),
      ];
      final alerts = selectNewAlerts(many, lastAlerted);
      expect(alerts, hasLength(3));
      expect(alerts.first.id, 'n9');
    });
  });
}
