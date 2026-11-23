import 'package:flutter_test/flutter_test.dart';
import 'package:terenza/features/collections/domain/payment_request_form.dart';

/// Règles d'activation du bouton « Vérifier la demande » (Nouvelle visite →
/// Avec demande de paiement). Liste vide = bouton actif.
List<String> issues({
  bool paymentAllowed = true,
  bool online = true,
  String? assignmentId = 'assignment',
  String? establishmentId = 'establishment',
  String amountText = '5000',
  String method = 'cash',
  int? obligationRemaining,
}) => paymentRequestIssues(
  paymentAllowed: paymentAllowed,
  online: online,
  assignmentId: assignmentId,
  establishmentId: establishmentId,
  amountText: amountText,
  method: method,
  obligationRemaining: obligationRemaining,
);

void main() {
  group('bouton « Vérifier la demande »', () {
    test('formulaire vide : désactivé, chaque champ manquant est expliqué', () {
      final result = issues(
        assignmentId: null,
        establishmentId: null,
        amountText: '',
      );
      expect(result, [
        'Choisissez une mission affectée.',
        'Choisissez le client (établissement) concerné.',
        'Saisissez le montant demandé.',
      ]);
    });

    test('client non sélectionné : désactivé', () {
      expect(issues(establishmentId: null), [
        'Choisissez le client (établissement) concerné.',
      ]);
    });

    test('montant nul : désactivé', () {
      expect(issues(amountText: '0'), [
        'Le montant doit être supérieur à zéro.',
      ]);
    });

    test('montant négatif : désactivé', () {
      expect(issues(amountText: '-500'), [
        'Le montant doit être supérieur à zéro.',
      ]);
    });

    test('montant invalide : désactivé', () {
      for (final raw in ['abc', '12,5', '1.5', '5e3', '--5']) {
        expect(issues(amountText: raw), [
          'Le montant doit être un nombre entier en FCFA, sans décimales.',
        ], reason: raw);
      }
    });

    test('montant au-delà du plafond serveur : désactivé', () {
      expect(issues(amountText: '100000001'), hasLength(1));
      expect(issues(amountText: '100000000'), isEmpty);
    });

    test('montant supérieur au solde de l’échéance choisie : désactivé', () {
      expect(
        issues(amountText: '6000', obligationRemaining: 5000),
        hasLength(1),
      );
      expect(issues(amountText: '5000', obligationRemaining: 5000), isEmpty);
    });

    test('tous les champs valides, sans échéance préalable : activé', () {
      expect(issues(), isEmpty);
      expect(issues(amountText: '5 000'), isEmpty);
      expect(issues(amountText: ' 7500 '), isEmpty);
    });

    test('sans droit ou sans connexion : désactivé avec la raison', () {
      expect(issues(paymentAllowed: false), [
        'Votre compte ne permet pas d’enregistrer une demande de paiement.',
      ]);
      expect(issues(online: false), [
        'Une connexion Internet est nécessaire pour une demande de paiement.',
      ]);
    });

    test('mode de paiement inconnu : désactivé', () {
      expect(issues(method: 'cheque'), ['Choisissez un mode de paiement.']);
    });
  });

  test('parsePaymentAmount accepte les espaces de groupement', () {
    expect(parsePaymentAmount('5 000'), 5000);
    expect(parsePaymentAmount('5 000'), 5000);
    expect(parsePaymentAmount('5000,00'), isNull);
    expect(parsePaymentAmount(''), isNull);
  });

  test('visite seule : mission et client suffisent', () {
    expect(visitIssues(assignmentId: 'a', establishmentId: 'e'), isEmpty);
    expect(
      visitIssues(assignmentId: null, establishmentId: null),
      hasLength(2),
    );
  });
}
