import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/features/receipts/application/receipt_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final receipt = ReceiptDocument(
    receiptNumber: 'R-2026-00000042',
    issuedAt: DateTime(2026, 10, 28, 16, 30),
    amount: 5000,
    method: 'cash',
    voided: false,
    organizationName: 'Mairie de Test',
    clientName: 'Boutique Kéné',
    taxpayerNumber: 'CT-001',
    establishmentName: 'Marché central',
    collectorName: 'Awa Traoré',
  );

  test('le reçu reprend les données réelles du paiement', () {
    final lines = Map.fromEntries(
      receipt.lines.map((l) => MapEntry(l.$1, l.$2)),
    );
    expect(lines['Reçu n°'], 'R-2026-00000042');
    expect(lines['Montant'], '5 000 FCFA');
    expect(lines['Mode de paiement'], 'Espèces');
    expect(lines['Client'], 'Boutique Kéné');
    expect(lines['Statut'], 'Payé');
    expect(lines.containsKey('Référence'), isFalse);
  });

  test('un reçu annulé est signalé comme tel', () {
    final voided = ReceiptDocument(
      receiptNumber: 'R-1',
      issuedAt: DateTime(2026, 10, 28),
      amount: 1,
      method: 'mobile_money',
      voided: true,
      providerReference: 'OM-123',
    );
    final lines = Map.fromEntries(
      voided.lines.map((l) => MapEntry(l.$1, l.$2)),
    );
    expect(lines['Statut'], 'Annulé');
    expect(lines['Référence'], 'OM-123');
  });

  test('caractères hors Latin-1 remplacés sans échec', () {
    expect(latin1Safe('l’opération — ok'), "l'opération - ok");
    expect(latin1Safe('Kéné ✓'), 'Kéné ?');
  });

  test('génère un véritable fichier PDF avec le logo', () async {
    final bytes = await buildReceiptPdf(receipt);
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(10000));
    expect(receipt.fileName, 'Recu-R-2026-00000042.pdf');
  });
}
