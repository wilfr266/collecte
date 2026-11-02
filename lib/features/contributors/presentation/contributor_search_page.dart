import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/presentation/taxpayer_payments_panel.dart';

class ContributorSearchPage extends ConsumerStatefulWidget {
  const ContributorSearchPage({super.key});

  @override
  ConsumerState<ContributorSearchPage> createState() =>
      _ContributorSearchPageState();
}

class _ContributorSearchPageState extends ConsumerState<ContributorSearchPage> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<_SearchResult> _results = [];
  bool _loading = false;
  bool _zonesLoading = true;
  String? _error;
  bool _activeOnly = true;
  String? _selectedZoneId;
  List<Map<String, dynamic>> _zones = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadZones);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _loadZones() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) {
      if (mounted) setState(() => _zonesLoading = false);
      return;
    }
    try {
      final rows = await client
          .from('zones')
          .select('id, name')
          .eq('is_active', true)
          .order('name')
          .limit(100);
      if (mounted) {
        setState(() {
          _zones = rows;
          _zonesLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _zonesLoading = false);
    }
  }

  Future<void> _search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.length < 2) {
      setState(() {
        _results = [];
        _error = null;
        _loading = false;
      });
      return;
    }
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Une seule requête serveur, limitée à l'organisation de l'appelant et filtrée
      // (zone, actifs) avant la limite ; RLS reste appliquée. Les jokers % et _ saisis
      // sont cherchés littéralement.
      final rows = await client.rpc<List<dynamic>>(
        'search_directory',
        params: {
          'p_query': query,
          'p_zone_id': _selectedZoneId,
          'p_active_only': _activeOnly,
          'p_limit': 40,
        },
      );

      final unique = <String, _SearchResult>{};
      for (final raw in rows) {
        final row = raw as Map<String, dynamic>;
        if (row['kind'] == 'taxpayer') {
          final result = _taxpayerResult({...row, 'legal_name': row['name']});
          unique['taxpayer:${result.id}'] = result;
        } else {
          final result = _SearchResult(
            id: row['id'] as String,
            kind: 'Établissement',
            title: row['name'] as String,
            subtitle: [row['address'], row['owner_name']]
                .whereType<String>()
                .where((value) => value.isNotEmpty)
                .join(' · '),
          );
          unique['establishment:${result.id}'] = result;
        }
      }
      if (!mounted) return;
      setState(() => _results = unique.values.toList());
    } on PostgrestException {
      if (mounted)
        setState(() => _error = 'Recherche impossible avec vos accès actuels.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Réseau indisponible. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  _SearchResult _taxpayerResult(Map<String, dynamic> row) {
    final kind = row['taxpayer_kind'] as String? ?? 'unspecified';
    final name = kind == 'individual'
        ? '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}'.trim()
        : row['legal_name'] as String;
    return _SearchResult(
      id: row['id'] as String,
      kind: kind == 'individual' ? 'Personne physique' : 'Contribuable',
      title: name.isEmpty ? row['legal_name'] as String : name,
      subtitle: [
        row['taxpayer_number'],
        row['phone'],
      ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recherche terrain')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Nom, téléphone, identifiant ou établissement',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Effacer la recherche',
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                  icon: const Icon(Icons.clear),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Actifs')),
                ButtonSegment(value: false, label: Text('Tous')),
              ],
              selected: {_activeOnly},
              onSelectionChanged: (selection) {
                setState(() => _activeOnly = selection.first);
                _search(_searchController.text);
              },
            ),
          ),
          if (!_zonesLoading && _zones.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedZoneId,
                decoration: const InputDecoration(labelText: 'Zone'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Toutes mes zones'),
                  ),
                  ..._zones.map(
                    (zone) => DropdownMenuItem<String?>(
                      value: zone['id'] as String,
                      child: Text(zone['name'] as String),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() => _selectedZoneId = value);
                  _search(_searchController.text);
                },
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, textAlign: TextAlign.center))
                : _searchController.text.trim().length < 2
                ? const Center(
                    child: Text('Saisissez au moins deux caractères.'),
                  )
                : _results.isEmpty && !_loading
                ? const Center(child: Text('Aucun résultat accessible.'))
                : ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _results.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      return ListTile(
                        leading: Icon(
                          result.kind == 'Contribuable'
                              ? Icons.person_outline
                              : Icons.storefront_outlined,
                        ),
                        title: Text(result.title),
                        subtitle: Text(
                          result.subtitle.isEmpty
                              ? result.kind
                              : '${result.kind} · ${result.subtitle}',
                        ),
                        onTap: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (context) => _SearchDetail(result: result),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _SearchResult {
  const _SearchResult({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
  });

  final String id;
  final String kind;
  final String title;
  final String subtitle;
}

class _SearchDetail extends ConsumerWidget {
  const _SearchDetail({required this.result});

  final _SearchResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(supabaseClientProvider);
    final roleKeys = ref.watch(currentRoleKeysProvider).valueOrNull ?? const [];
    final organizationId = ref
        .watch(currentProfileProvider)
        .valueOrNull
        ?.organizationId;
    if (client == null) {
      return const SafeArea(
        child: Text('Service indisponible. Réessayez dans quelques instants.'),
      );
    }
    final detailFuture = result.kind == 'Établissement'
        ? client
              .from('establishments')
              .select(
                'id, name, address, is_active, latitude, longitude, activity_types(label), taxpayers(id, legal_name, taxpayer_kind, first_name, last_name, taxpayer_number, phone)',
              )
              .eq('id', result.id)
              .maybeSingle()
        : client
              .from('taxpayers')
              .select(
                'id, legal_name, taxpayer_kind, first_name, last_name, taxpayer_number, phone, email, address, zones(name), establishments(id, name, address, is_active)',
              )
              .eq('id', result.id)
              .maybeSingle();

    return SafeArea(
      child: FutureBuilder<Map<String, dynamic>?>(
        future: detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final detail = snapshot.data;
          if (snapshot.hasError || detail == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Fiche indisponible avec vos accès ou votre connexion.',
              ),
            );
          }
          final isEstablishment = result.kind == 'Établissement';
          final personName =
              '${detail['first_name'] ?? ''} ${detail['last_name'] ?? ''}'
                  .trim();
          final title = isEstablishment
              ? detail['name'] as String
              : (personName.isEmpty
                    ? detail['legal_name'] as String
                    : personName);
          final linkedTaxpayer = detail['taxpayers'] as Map<String, dynamic>?;
          final establishments =
              detail['establishments'] as List<dynamic>? ?? const [];
          final establishmentIds = isEstablishment
              ? [result.id]
              : establishments
                    .map(
                      (item) => (item as Map<String, dynamic>)['id'] as String,
                    )
                    .toList();
          final activityType =
              detail['activity_types'] as Map<String, dynamic>?;
          // Client concerné et lieux d'encaissement possibles (établissements actifs).
          final taxpayerId = isEstablishment
              ? (linkedTaxpayer?['id'] as String?)
              : (detail['id'] as String?);
          final activeEstablishments = isEstablishment
              ? [
                  if (detail['is_active'] == true)
                    {'id': detail['id'], 'name': detail['name']},
                ]
              : [
                  for (final item in establishments)
                    if ((item as Map<String, dynamic>)['is_active'] == true)
                      {'id': item['id'], 'name': item['name']},
                ];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                isEstablishment
                    ? 'Établissement'
                    : _taxpayerKindLabel(detail['taxpayer_kind'] as String?),
              ),
              if (detail['address'] != null) Text(detail['address'] as String),
              if (activityType?['label'] != null)
                Text('Activité · ${activityType!['label']}'),
              if (detail['phone'] != null)
                Text('Téléphone · ${detail['phone']}'),
              if (detail['email'] != null) Text('E-mail · ${detail['email']}'),
              if (detail['taxpayer_number'] != null)
                Text('N° contribuable · ${detail['taxpayer_number']}'),
              if (linkedTaxpayer != null) ...[
                const SizedBox(height: 12),
                Text('Contribuable · ${linkedTaxpayer['legal_name']}'),
              ],
              if (establishments.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Établissements (${establishments.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final item in establishments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item['name'] as String),
                    subtitle: Text(item['address'] as String? ?? ''),
                    trailing: Text(
                      item['is_active'] == true ? 'Actif' : 'Inactif',
                    ),
                  ),
              ],
              if (establishmentIds.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Historique des visites',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _VisitHistory(establishmentIds: establishmentIds),
              ],
              if (taxpayerId != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Paiements',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TaxpayerPaymentsPanel(
                  taxpayerId: taxpayerId,
                  establishments: activeEstablishments,
                  title: isEstablishment
                      ? (linkedTaxpayer?['legal_name'] as String? ?? title)
                      : title,
                  details: [
                    if (detail['taxpayer_number'] != null)
                      'N° contribuable · ${detail['taxpayer_number']}',
                    if (detail['phone'] != null)
                      'Téléphone · ${detail['phone']}',
                  ],
                  canRecord: roleKeys.contains('collector'),
                  organizationId: organizationId,
                ),
              ],
              const SizedBox(height: 12),
              const SizedBox(height: 8),
              const Text(
                'Identifiant',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SelectableText(result.id),
            ],
          );
        },
      ),
    );
  }
}

class _VisitHistory extends ConsumerWidget {
  const _VisitHistory({required this.establishmentIds});

  final List<String> establishmentIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(supabaseClientProvider);
    if (client == null) return const Text('Historique indisponible.');
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: client
          .from('collections')
          .select('id, visited_at, outcome, status, establishments(name)')
          .inFilter('establishment_id', establishmentIds)
          .order('visited_at', ascending: false)
          .limit(20),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(),
          );
        }
        if (snapshot.hasError) return const Text('Historique non accessible.');
        final visits = snapshot.data ?? [];
        if (visits.isEmpty) return const Text('Aucune visite accessible.');
        return Column(
          children: [
            for (final visit in visits)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_visitOutcome(visit['outcome'] as String)),
                subtitle: Text(
                  '${visit['establishments']?['name'] ?? ''} · ${_visitDate(visit['visited_at'] as String)} · ${visit['status']}',
                ),
              ),
          ],
        );
      },
    );
  }

  String _visitOutcome(String value) => switch (value) {
    'contacted' => 'Contact effectué',
    'unavailable' => 'Contribuable absent',
    'refused' => 'Refus',
    _ => 'Suivi à prévoir',
  };

  String _visitDate(String value) {
    final date = DateTime.parse(value).toLocal();
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}

String _taxpayerKindLabel(String? value) => switch (value) {
  'individual' => 'Personne physique',
  'business' => 'Entreprise',
  _ => 'Type à vérifier',
};
