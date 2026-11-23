import '../../../core/utils/currency_formatter.dart';

/// Plafond accepté par le serveur (`record_collection_payment_request`).
const maxPaymentRequestAmount = 100000000;

/// Modes acceptés par `record_collection_payment_request`.
const paymentRequestMethods = {
  'cash',
  'mobile_money',
  'bank_transfer',
  'card',
  'other',
};

/// Montant entier en FCFA. Les espaces de groupement (« 5 000 ») sont admis ;
/// renvoie `null` si la saisie n'est pas un entier.
int? parsePaymentAmount(String raw) {
  final normalized = raw.replaceAll(RegExp(r'[\s  ]'), '');
  if (!RegExp(r'^-?\d{1,12}$').hasMatch(normalized)) return null;
  return int.tryParse(normalized);
}

/// Message d'erreur du montant, ou `null` s'il est valide.
/// [obligationRemaining] : solde de l'échéance choisie, s'il y en a une.
String? paymentAmountError(String raw, {int? obligationRemaining}) {
  if (raw.trim().isEmpty) return 'Saisissez le montant demandé.';
  final amount = parsePaymentAmount(raw);
  if (amount == null) {
    return 'Le montant doit être un nombre entier en FCFA, sans décimales.';
  }
  if (amount <= 0) return 'Le montant doit être supérieur à zéro.';
  if (amount > maxPaymentRequestAmount) {
    return 'Le montant dépasse le plafond autorisé '
        '(${CurrencyFormatter.formatCfa(maxPaymentRequestAmount)}).';
  }
  if (obligationRemaining != null && amount > obligationRemaining) {
    return 'Le montant dépasse le solde de l’échéance choisie '
        '(${CurrencyFormatter.formatCfa(obligationRemaining)}).';
  }
  return null;
}

/// Ce qui empêche encore de vérifier une demande de paiement, dans l'ordre du
/// formulaire. Liste vide : le bouton « Vérifier la demande » est actif.
///
/// Les mêmes règles sont revérifiées par le serveur ; elles ne servent ici qu'à
/// guider le collecteur.
List<String> paymentRequestIssues({
  required bool paymentAllowed,
  required bool online,
  required String? assignmentId,
  required String? establishmentId,
  required String amountText,
  required String method,
  int? obligationRemaining,
}) {
  if (!paymentAllowed) {
    return const [
      'Votre compte ne permet pas d’enregistrer une demande de paiement.',
    ];
  }
  if (!online) {
    return const [
      'Une connexion Internet est nécessaire pour une demande de paiement.',
    ];
  }
  final issues = <String>[];
  if (assignmentId == null) issues.add('Choisissez une mission affectée.');
  if (establishmentId == null) {
    issues.add('Choisissez le client (établissement) concerné.');
  }
  final amountError = paymentAmountError(
    amountText,
    obligationRemaining: obligationRemaining,
  );
  if (amountError != null) issues.add(amountError);
  if (!paymentRequestMethods.contains(method)) {
    issues.add('Choisissez un mode de paiement.');
  }
  return issues;
}

/// Ce qui empêche encore d'enregistrer une visite seule.
List<String> visitIssues({
  required String? assignmentId,
  required String? establishmentId,
}) => [
  if (assignmentId == null) 'Choisissez une mission affectée.',
  if (establishmentId == null) 'Choisissez le client (établissement) visité.',
];
