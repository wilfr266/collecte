import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../shared/widgets/state_views.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/domain/payment_labels.dart';

/// Paiements enregistrés par le collecteur, tous statuts confondus.
///
/// RLS `payments_read_scoped` limite la lecture aux collectes accessibles ;
/// le filtre `recorded_by` restreint à ses propres saisies.
final collectorTransactionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile?.organizationId == null) return [];
      return client
          .from('payments')
          .select(
            'id, amount, method, status, failure_reason, provider_reference, created_at, confirmed_at, receipts(receipt_number, status), collections(establishments(name))',
          )
          .eq('organization_id', profile!.organizationId!)
          .eq('recorded_by', profile.id)
          .order('created_at', ascending: false)
          .limit(100);
    });

class TransactionsPage extends ConsumerWidget {
  const TransactionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactions = ref.watch(collectorTransactionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mes transactions')),
      body: transactions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => StateMessageView.error(
          message:
              'Les transactions ne sont pas disponibles. Vérifiez vos accès ou le réseau.',
          onRetry: () => ref.invalidate(collectorTransactionsProvider),
        ),
        data: (items) => items.isEmpty
            ? const StateMessageView(
                icon: Icons.swap_vert,
                message:
                    'Aucune transaction enregistrée. Vos encaissements apparaîtront ici avec leur statut.',
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(collectorTransactionsProvider);
                  await ref.read(collectorTransactionsProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final row in items) _TransactionTile(row: row),
                  ],
                ),
              ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final receipt = _single(row['receipts']);
    final establishment = _single(
      _single(row['collections'])?['establishments'],
    );
    return Card(
      child: ListTile(
        leading: const Icon(Icons.swap_vert),
        title: Text(
          '${CurrencyFormatter.formatCfa((row['amount'] as num).toInt())} · ${paymentMethodLabel(row['method'] as String)}',
        ),
        subtitle: Text(
          [
            establishment?['name'] as String? ?? 'Établissement',
            'Saisi le ${_date(row['created_at'])}',
            if (receipt != null) 'Reçu ${receipt['receipt_number']}',
            if (row['provider_reference'] != null)
              'Référence ${row['provider_reference']}',
            ?paymentStatusHint(
              row['status'] as String,
              failureReason: row['failure_reason'] as String?,
            ),
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: Chip(
          label: Text(
            paymentStatusLabel(
              row['status'] as String,
              method: row['method'] as String,
              failureReason: row['failure_reason'] as String?,
            ),
          ),
        ),
      ),
    );
  }
}

/// PostgREST renvoie un objet ou une liste selon la cardinalité détectée.
Map<String, dynamic>? _single(Object? value) => switch (value) {
  Map<String, dynamic> map => map,
  List<dynamic> list when list.isNotEmpty => list.first as Map<String, dynamic>,
  _ => null,
};

String _date(Object? value) {
  final date = DateTime.tryParse(value as String? ?? '')?.toLocal();
  if (date == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} ${two(date.hour)}:${two(date.minute)}';
}
