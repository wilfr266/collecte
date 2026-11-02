import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/domain/payment_labels.dart';
import '../../profile/presentation/organization_card.dart';
import '../application/receipt_pdf.dart';

final receiptsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) async {
  final client = ref.watch(supabaseClientProvider);
  final profile = await ref.watch(currentProfileProvider.future);
  if (client == null || profile?.organizationId == null) return [];
  return client
      .from('receipts')
      .select(
        'id, receipt_number, status, issued_at, voided_at, payments!inner(amount, currency_code, method, status, confirmed_at, provider_reference, collections(visited_at, establishments(name, taxpayers(legal_name, taxpayer_number))))',
      )
      .eq('organization_id', profile!.organizationId!)
      .order('issued_at', ascending: false)
      .limit(50);
});

class ReceiptsPage extends ConsumerWidget {
  const ReceiptsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receipts = ref.watch(receiptsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Reçus')),
      body: receipts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Les reçus ne sont pas disponibles. Vérifiez vos accès ou le réseau.',
            ),
          ),
        ),
        data: (items) {
          final confirmed = items.where((row) {
            final payment = row['payments'] as Map<String, dynamic>?;
            return payment?['status'] == 'confirmed';
          }).toList();
          if (confirmed.isEmpty)
            return const Center(child: Text('Aucun reçu confirmé.'));
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(receiptsProvider);
              await ref.read(receiptsProvider.future);
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: confirmed.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final receipt = confirmed[index];
                final payment = receipt['payments'] as Map<String, dynamic>;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(receipt['receipt_number'] as String),
                    subtitle: Text(
                      '${CurrencyFormatter.formatCfa((payment['amount'] as num).toInt())} · ${paymentMethodLabel(payment['method'] as String)}',
                    ),
                    trailing: Chip(
                      label: Text(
                        receipt['status'] == 'issued' ? 'Émis' : 'Annulé',
                      ),
                    ),
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (context) =>
                          _ReceiptDetails(receipt: receipt, payment: payment),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ReceiptDetails extends ConsumerStatefulWidget {
  const _ReceiptDetails({required this.receipt, required this.payment});

  final Map<String, dynamic> receipt;
  final Map<String, dynamic> payment;

  @override
  ConsumerState<_ReceiptDetails> createState() => _ReceiptDetailsState();
}

class _ReceiptDetailsState extends ConsumerState<_ReceiptDetails> {
  bool _sharing = false;

  ReceiptDocument _document() {
    final collection = _single(widget.payment['collections']);
    final establishment = _single(collection?['establishments']);
    final taxpayer = _single(establishment?['taxpayers']);
    return ReceiptDocument(
      receiptNumber: widget.receipt['receipt_number'] as String,
      issuedAt: DateTime.parse(widget.receipt['issued_at'] as String),
      amount: (widget.payment['amount'] as num).toInt(),
      method: widget.payment['method'] as String,
      voided: widget.receipt['status'] != 'issued',
      organizationName:
          ref.read(currentOrganizationProvider).valueOrNull?['name'] as String?,
      clientName: taxpayer?['legal_name'] as String?,
      taxpayerNumber: taxpayer?['taxpayer_number'] as String?,
      establishmentName: establishment?['name'] as String?,
      providerReference: widget.payment['provider_reference'] as String?,
      collectorName: ref.read(currentProfileProvider).valueOrNull?.displayName,
    );
  }

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharing = true);
    try {
      await shareReceiptPdf(_document(), sharePositionOrigin: origin);
    } catch (error) {
      if (kDebugMode) debugPrint('[Reçu] Partage : $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Le reçu n’a pas pu être généré. Réessayez.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nom de l'organisation chargé à l'avance pour l'en-tête du reçu.
    ref.watch(currentOrganizationProvider);
    final document = _document();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Reçu ${document.receiptNumber}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            for (final (label, value) in document.lines.skip(1))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('$label · $value'),
              ),
            const SizedBox(height: 20),
            Builder(
              builder: (buttonContext) => FilledButton.icon(
                onPressed: _sharing ? null : () => _share(buttonContext),
                icon: _sharing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.picture_as_pdf_outlined),
                label: Text(
                  _sharing ? 'Préparation du reçu…' : 'Partager le reçu (PDF)',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PostgREST renvoie un objet ou une liste selon la relation.
Map<String, dynamic>? _single(Object? value) => switch (value) {
  Map<String, dynamic> map => map,
  List<dynamic> list when list.isNotEmpty => list.first as Map<String, dynamic>,
  _ => null,
};
