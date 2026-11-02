/// Libellés communs des paiements (`public.payments`), partagés par les
/// espaces client et collecteur pour afficher le même état de transaction.
///
/// L'état affiché est toujours celui renvoyé par Supabase : seul le serveur
/// confirme un paiement (caisse ou notification vérifiée du fournisseur).
library;

String paymentMethodLabel(String method) => switch (method) {
  'cash' => 'Espèces',
  'mobile_money' => 'Mobile Money',
  'bank_transfer' => 'Virement',
  'card' => 'Carte',
  _ => 'Autre moyen',
};

bool isExternalPaymentMethod(String method) =>
    method == 'mobile_money' || method == 'bank_transfer' || method == 'card';

/// Statut lisible ; [failureReason] précise un échec (colonne
/// `payments.failure_reason`, nulle pour l'historique).
String paymentStatusLabel(
  String status, {
  String? method,
  String? failureReason,
}) => switch (status) {
  // Aucun opérateur intégré : l'organisation vérifie la référence sur son relevé.
  'pending' when method == 'mobile_money' => 'En attente de vérification',
  'pending' when method != null && isExternalPaymentMethod(method) =>
    'En attente de l’opérateur',
  'pending' when method == 'cash' => 'En attente de validation caisse',
  'pending' => 'En attente',
  'confirmed' => 'Confirmé',
  'failed' => switch (failureReason) {
    'cancelled' => 'Annulé',
    'timeout' => 'Délai dépassé',
    'late_success_needs_review' => 'En vérification',
    'provider_failed' => 'Refusé',
    _ => 'Échoué',
  },
  'reversed' => 'Remboursé',
  _ => status,
};

/// Explication complémentaire pour les états qui demandent un éclairage.
String? paymentStatusHint(String status, {String? failureReason}) => switch ((
  status,
  failureReason,
)) {
  ('pending', _) =>
    'Le paiement n’est pas encore confirmé ; aucun reçu n’est émis.',
  ('failed', 'timeout') =>
    'Aucune confirmation reçue à temps. Si l’opérateur confirme plus tard, le paiement sera mis à jour.',
  ('failed', 'late_success_needs_review') =>
    'Confirmation tardive en cours de vérification par l’administration.',
  _ => null,
};
