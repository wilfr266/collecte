import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/presentation/client_finance_screen.dart';

/// Clients du collecteur : contribuables des zones de ses missions actives
/// (RLS `taxpayers_read_scoped`). Un appui ouvre la fiche financière.
class ClientsPage extends ConsumerStatefulWidget {
  const ClientsPage({super.key});

  @override
  ConsumerState<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends ConsumerState<ClientsPage> {
  static const _pageSize = 30;

  final _search = TextEditingController();
  Timer? _debounce;
  final List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    final client = ref.read(supabaseClientProvider);
    if (client == null || (_loading && !reset)) return;
    final generation = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Caractères de syntaxe PostgREST retirés : la recherche reste littérale.
      final term = _search.text
          .trim()
          .replaceAll(RegExp(r'[,()"\\%_*:]'), ' ')
          .trim();
      var query = client
          .from('taxpayers')
          .select(
            'id, legal_name, taxpayer_kind, first_name, last_name, taxpayer_number, phone, is_active, zones(name), establishments(id, name, is_active)',
          )
          .eq('is_active', true);
      if (term.isNotEmpty) {
        query = query.or(
          'legal_name.ilike.*$term*,taxpayer_number.ilike.*$term*,phone.ilike.*$term*,first_name.ilike.*$term*,last_name.ilike.*$term*',
        );
      }
      final offset = reset ? 0 : _rows.length;
      final rows = await query
          .order('legal_name')
          .range(offset, offset + _pageSize - 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(rows);
        _hasMore = rows.length == _pageSize;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error =
              'Clients indisponibles avec vos accès ou votre connexion.',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _name(Map<String, dynamic> row) {
    final person = '${row['first_name'] ?? ''} ${row['last_name'] ?? ''}'
        .trim();
    return row['taxpayer_kind'] == 'individual' && person.isNotEmpty
        ? person
        : row['legal_name'] as String;
  }

  void _open(Map<String, dynamic> row) {
    final roleKeys = ref.read(currentRoleKeysProvider).valueOrNull ?? const [];
    final profile = ref.read(currentProfileProvider).valueOrNull;
    final establishments = [
      for (final e in (row['establishments'] as List<dynamic>? ?? const []))
        if ((e as Map<String, dynamic>)['is_active'] == true)
          {'id': e['id'], 'name': e['name']},
    ];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClientFinanceScreen(
          taxpayerId: row['id'] as String,
          title: _name(row),
          details: [
            if (row['taxpayer_number'] != null)
              'N° contribuable · ${row['taxpayer_number']}',
            if (row['phone'] != null) 'Téléphone · ${row['phone']}',
            if ((row['zones'] as Map<String, dynamic>?)?['name'] != null)
              'Zone · ${row['zones']['name']}',
          ],
          establishments: establishments,
          canRecord: roleKeys.contains('collector'),
          organizationId: profile?.organizationId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Mes clients'),
      actions: [
        IconButton(
          tooltip: 'Recherche terrain (établissements)',
          onPressed: () => context.push('/search'),
          icon: const Icon(Icons.travel_explore),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 350),
                () => _load(reset: true),
              );
            },
            decoration: const InputDecoration(
              labelText: 'Nom, identifiant ou téléphone',
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: _error != null
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: () => _load(reset: true),
                        child: const Text('Réessayer'),
                      ),
                    ],
                  )
                : _rows.isEmpty && !_loading
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: const [
                      Text(
                        'Aucun client accessible. Vos clients apparaissent quand votre organisation vous affecte à une mission ou à un client.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : ListView.separated(
                    itemCount: _rows.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == _rows.length) {
                        return Center(
                          child: TextButton(
                            onPressed: _loading
                                ? null
                                : () => _load(reset: false),
                            child: const Text('Charger plus'),
                          ),
                        );
                      }
                      final row = _rows[index];
                      return ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(_name(row)),
                        subtitle: Text(
                          [
                                row['taxpayer_number'],
                                row['phone'],
                                (row['zones']
                                    as Map<String, dynamic>?)?['name'],
                              ]
                              .whereType<String>()
                              .where((v) => v.isNotEmpty)
                              .join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(row),
                      );
                    },
                  ),
          ),
        ),
      ],
    ),
  );
}
