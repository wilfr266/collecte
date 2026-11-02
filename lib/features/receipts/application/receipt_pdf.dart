import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../../core/utils/currency_formatter.dart';
import '../../payments/domain/payment_labels.dart';

/// Données d'un reçu, toutes issues de l'enregistrement réel du paiement.
class ReceiptDocument {
  const ReceiptDocument({
    required this.receiptNumber,
    required this.issuedAt,
    required this.amount,
    required this.method,
    required this.voided,
    this.organizationName,
    this.clientName,
    this.taxpayerNumber,
    this.establishmentName,
    this.providerReference,
    this.collectorName,
  });

  final String receiptNumber;
  final DateTime issuedAt;
  final int amount;
  final String method;
  final bool voided;
  final String? organizationName;
  final String? clientName;
  final String? taxpayerNumber;
  final String? establishmentName;
  final String? providerReference;
  final String? collectorName;

  /// Lignes du reçu, dans l'ordre d'affichage (libellé, valeur).
  List<(String, String)> get lines => [
    ('Reçu n°', receiptNumber),
    ('Date', _dateTime(issuedAt)),
    if (clientName != null) ('Client', clientName!),
    if (taxpayerNumber != null) ('N° contribuable', taxpayerNumber!),
    if (establishmentName != null) ('Établissement', establishmentName!),
    ('Montant', CurrencyFormatter.formatCfa(amount)),
    ('Mode de paiement', paymentMethodLabel(method)),
    if (providerReference != null) ('Référence', providerReference!),
    if (collectorName != null) ('Encaissé par', collectorName!),
    ('Statut', voided ? 'Annulé' : 'Payé'),
  ];

  String get fileName =>
      'Recu-${receiptNumber.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_')}.pdf';
}

String _dateTime(DateTime value) {
  final d = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} à ${two(d.hour)} h ${two(d.minute)}';
}

/// Les polices PDF intégrées ne couvrent que le Latin-1 : apostrophe
/// typographique et tirets longs sont remplacés, tout autre caractère hors
/// Latin-1 devient « ? » plutôt que de faire échouer la génération.
@visibleForTesting
String latin1Safe(String text) {
  final normalized = text
      .replaceAll('’', "'")
      .replaceAll('‘', "'")
      .replaceAll('—', '-')
      .replaceAll('–', '-')
      .replaceAll(' ', ' ')
      .replaceAll(' ', ' ');
  return String.fromCharCodes(
    normalized.runes.map((r) => r <= 0xff ? r : 0x3f),
  );
}

/// Construit le PDF du reçu (format A5).
Future<Uint8List> buildReceiptPdf(ReceiptDocument receipt) async {
  final logo = await rootBundle.load('assets/branding/terenza_logo.png');
  final document = pw.Document(
    title: latin1Safe('Reçu ${receipt.receiptNumber}'),
    author: 'Terenza',
  );
  final accent = PdfColor.fromInt(0xFF0B6BCB);
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            children: [
              pw.ClipRRect(
                horizontalRadius: 8,
                verticalRadius: 8,
                child: pw.Image(
                  pw.MemoryImage(logo.buffer.asUint8List()),
                  width: 56,
                  height: 56,
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      latin1Safe('Reçu de paiement'),
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: accent,
                      ),
                    ),
                    if (receipt.organizationName != null)
                      pw.Text(latin1Safe(receipt.organizationName!)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          if (receipt.voided)
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(8),
              margin: const pw.EdgeInsets.only(bottom: 12),
              color: PdfColors.red50,
              child: pw.Text(
                latin1Safe(
                  'REÇU ANNULÉ - ce document ne vaut pas preuve de paiement.',
                ),
                style: pw.TextStyle(
                  color: PdfColors.red800,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          pw.Table(
            columnWidths: {
              0: const pw.FlexColumnWidth(2),
              1: const pw.FlexColumnWidth(3),
            },
            border: pw.TableBorder(
              horizontalInside: pw.BorderSide(color: PdfColors.grey300),
            ),
            children: [
              for (final (label, value) in receipt.lines)
                pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 6),
                      child: pw.Text(
                        latin1Safe(label),
                        style: const pw.TextStyle(color: PdfColors.grey700),
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 6),
                      child: pw.Text(
                        latin1Safe(value),
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          pw.Spacer(),
          pw.Divider(color: PdfColors.grey400),
          pw.Text(
            latin1Safe(
              'Reçu émis par Terenza le ${_dateTime(receipt.issuedAt)}. '
              'Conservez ce document comme justificatif de paiement.',
            ),
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    ),
  );
  return document.save();
}

/// Génère le reçu et ouvre le partage du système (WhatsApp, e-mail,
/// impression, enregistrement…).
Future<void> shareReceiptPdf(
  ReceiptDocument receipt, {
  Rect? sharePositionOrigin,
}) async {
  final bytes = await buildReceiptPdf(receipt);
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/${receipt.fileName}');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      subject: latin1Safe('Reçu ${receipt.receiptNumber}'),
      text: 'Reçu de paiement ${receipt.receiptNumber}',
      sharePositionOrigin: sharePositionOrigin,
    ),
  );
}
