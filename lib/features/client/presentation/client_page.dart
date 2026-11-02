import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/live_refresh.dart';
import '../../../core/network/supabase_client_provider.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/presentation/taxpayer_payments_panel.dart';
import '../../profile/presentation/organization_card.dart';

/// Contribuables rattachés au compte client (`client_taxpayer_links`).
///
/// Le filtre par lien est explicite : un compte cumulant client et
/// collecteur ne doit pas voir ici les contribuables de ses zones.
final clientTaxpayersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile?.organizationId == null) return [];
      final links = await client
          .from('client_taxpayer_links')
          .select('taxpayer_id')
          .eq('organization_id', profile!.organizationId!)
          .eq('user_id', profile.id);
      final ids = links.map((row) => row['taxpayer_id'] as String).toList();
      if (ids.isEmpty) return [];
      return client
          .from('taxpayers')
          .select('id, legal_name, taxpayer_number, phone, email, address')
          .inFilter('id', ids)
          .order('legal_name');
    });

/// Établissements des contribuables rattachés : informations de service.
final clientEstablishmentsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final taxpayers = await ref.watch(clientTaxpayersProvider.future);
      if (client == null || taxpayers.isEmpty) return [];
      return client
          .from('establishments')
          .select('id, name, address, is_active, activity_types(label)')
          .inFilter('taxpayer_id', taxpayers.map((t) => t['id']).toList())
          .order('name');
    });

/// Obligations (échéances) des contribuables rattachés.
///
/// Le solde restant est `amount_due - amount_paid` : le schéma garantit
/// `amount_paid <= amount_due` et seule une confirmation serveur de paiement
/// incrémente `amount_paid`.
final clientObligationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final taxpayers = await ref.watch(clientTaxpayersProvider.future);
      if (client == null || taxpayers.isEmpty) return [];
      return client
          .from('financial_obligations')
          .select(
            'id, taxpayer_id, period_start, period_end, due_date, amount_due, amount_paid, status, tax_types(label), establishments(name)',
          )
          .inFilter('taxpayer_id', taxpayers.map((t) => t['id']).toList())
          .neq('status', 'cancelled')
          .order('due_date');
    });

/// Historique des paiements (tous statuts) via la RPC `client_payments`.
final clientPaymentsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      if (client == null) return [];
      final rows = await client.rpc(
        'client_payments',
        params: {'p_limit': 100},
      );
      return (rows as List<dynamic>).cast<Map<String, dynamic>>();
    });

/// Espace client : lecture seule des données réelles des contribuables
/// rattachés. Aucun paiement n'est initié depuis cet écran.
class ClientPage extends ConsumerWidget {
  const ClientPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taxpayers = ref.watch(clientTaxpayersProvider);
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    if (profile == null) return _content(context, ref, taxpayers);
    // Mise à jour automatique : paiement confirmé (obligation mise à jour),
    // nouveau rattachement, notification ; secours périodique sinon.
    return LiveRefresh(
      channel: 'client-space-${profile.id}',
      sources: [
        if (profile.organizationId != null)
          LiveSource(
            'financial_obligations',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'organization_id',
              value: profile.organizationId,
            ),
          ),
        LiveSource(
          'client_taxpayer_links',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: profile.id,
          ),
        ),
      ],
      onRefresh: () {
        ref.invalidate(clientTaxpayersProvider);
        ref.invalidate(clientPaymentsProvider);
      },
      child: _content(context, ref, taxpayers),
    );
  }

  Widget _content(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Map<String, dynamic>>> taxpayers,
  ) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mon espace'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Résumé'),
              Tab(text: 'Échéances'),
              Tab(text: 'Paiements'),
            ],
          ),
        ),
        body: taxpayers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => _Message(
            'Vos informations ne sont pas disponibles. Vérifiez vos accès ou le réseau.',
            onRefresh: () => _refreshAll(ref),
          ),
          data: (items) => items.isEmpty
              ? _Message(
                  'Aucun contribuable n’est encore rattaché à votre compte. Contactez votre administration pour finaliser le rattachement.',
                  onRefresh: () => _refreshAll(ref),
                )
              : TabBarView(
                  children: [
                    _SummaryTab(taxpayers: items),
                    const _ObligationsTab(),
                    _PaymentsTab(taxpayers: items),
                  ],
                ),
        ),
      ),
    );
  }
}

Future<void> _refreshAll(WidgetRef ref) async {
  ref.invalidate(clientTaxpayersProvider);
  ref.invalidate(clientPaymentsProvider);
  await ref.read(clientTaxpayersProvider.future);
}

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab({required this.taxpayers});

  final List<Map<String, dynamic>> taxpayers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final establishments = ref.watch(clientEstablishmentsProvider);
    final obligations = ref.watch(clientObligationsProvider).valueOrNull;
    final remaining = obligations?.fold<int>(
      0,
      (sum, row) => sum + _remaining(row),
    );
    return RefreshIndicator(
      onRefresh: () => _refreshAll(ref),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const OrganizationCard(),
          if (remaining != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(CurrencyFormatter.formatCfa(remaining)),
                subtitle: const Text(
                  'Solde restant sur les échéances en cours',
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('Contribuable', style: Theme.of(context).textTheme.titleMedium),
          for (final taxpayer in taxpayers)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      taxpayer['legal_name'] as String,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      'N° ${taxpayer['taxpayer_number'] ?? 'non renseigné'}',
                    ),
                    if (taxpayer['phone'] != null)
                      Text('Téléphone · ${taxpayer['phone']}'),
                    if (taxpayer['email'] != null)
                      Text('Email · ${taxpayer['email']}'),
                    if (taxpayer['address'] != null)
                      Text('Adresse · ${taxpayer['address']}'),
                  ],
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Les coordonnées du contribuable sont gérées par l’administration. Votre nom d’affichage et votre téléphone se modifient depuis votre profil.',
            ),
          ),
          const SizedBox(height: 8),
          // Bilan du mois : paiements avec date, heure, montant, mode et reçu.
          for (final taxpayer in taxpayers) ...[
            if (taxpayers.length > 1)
              Text(
                taxpayer['legal_name'] as String,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            TaxpayerPaymentsPanel(
              taxpayerId: taxpayer['id'] as String,
              establishments: const [],
              title: taxpayer['legal_name'] as String,
              organizationId: ref
                  .watch(currentProfileProvider)
                  .valueOrNull
                  ?.organizationId,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Établissements et services',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          establishments.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, stackTrace) =>
                const Text('Les établissements ne sont pas disponibles.'),
            data: (items) => items.isEmpty
                ? const Text('Aucun établissement enregistré.')
                : Column(
                    children: [
                      for (final row in items)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.storefront_outlined),
                            title: Text(row['name'] as String),
                            subtitle: Text(
                              [
                                (row['activity_types']
                                        as Map<String, dynamic>?)?['label']
                                    as String?,
                                row['address'] as String?,
                              ].whereType<String>().join(' · '),
                            ),
                            trailing: row['is_active'] == true
                                ? null
                                : const Chip(label: Text('Inactif')),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ObligationsTab extends ConsumerWidget {
  const _ObligationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final obligations = ref.watch(clientObligationsProvider);
    return obligations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => _Message(
        'Les échéances ne sont pas disponibles.',
        onRefresh: () => _refreshAll(ref),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _Message(
            'Aucune échéance enregistrée.',
            onRefresh: () => _refreshAll(ref),
          );
        }
        return RefreshIndicator(
          onRefresh: () => _refreshAll(ref),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final row in items)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.request_quote_outlined),
                    title: Text(
                      (row['tax_types'] as Map<String, dynamic>?)?['label']
                              as String? ??
                          'Taxe',
                    ),
                    subtitle: Text(
                      '${(row['establishments'] as Map<String, dynamic>?)?['name'] ?? ''}\n'
                      'Période ${row['period_start']} → ${row['period_end']} · échéance ${row['due_date']}\n'
                      'Dû ${_cfa(row['amount_due'])} · payé ${_cfa(row['amount_paid'])} · reste ${CurrencyFormatter.formatCfa(_remaining(row))}',
                    ),
                    isThreeLine: true,
                    trailing: Chip(
                      label: Text(_obligationStatus(row['status'] as String)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Paiements : bilan mensuel et historique jour par jour de chaque
/// contribuable rattaché, calculés par le serveur avec les mêmes règles que
/// l'espace collecteur (paiements confirmés uniquement dans le total).
class _PaymentsTab extends ConsumerWidget {
  const _PaymentsTab({required this.taxpayers});

  final List<Map<String, dynamic>> taxpayers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organizationId = ref
        .watch(currentProfileProvider)
        .valueOrNull
        ?.organizationId;
    return RefreshIndicator(
      onRefresh: () => _refreshAll(ref),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final taxpayer in taxpayers) ...[
            if (taxpayers.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  taxpayer['legal_name'] as String,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            TaxpayerPaymentsPanel(
              taxpayerId: taxpayer['id'] as String,
              establishments: const [],
              title: taxpayer['legal_name'] as String,
              organizationId: organizationId,
            ),
          ],
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Seul un paiement confirmé donne lieu à un reçu et compte dans le total payé.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {required this.onRefresh});

  final String text;
  final Future<void> Function() onRefresh;

  // ListView pour conserver le geste « tirer pour actualiser ».
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [Text(text, textAlign: TextAlign.center)],
    ),
  );
}

int _remaining(Map<String, dynamic> row) =>
    (row['amount_due'] as num).toInt() - (row['amount_paid'] as num).toInt();

String _cfa(Object? value) =>
    CurrencyFormatter.formatCfa((value as num).toInt());

String _obligationStatus(String status) => switch (status) {
  'open' => 'À payer',
  'partial' => 'Partiel',
  'paid' => 'Soldé',
  _ => status,
};
