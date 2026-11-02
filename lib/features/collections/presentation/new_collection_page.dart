import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../core/network/offline_store.dart';
import '../../../core/network/offline_sync_manager.dart';
import '../../../core/security/visit_location_service.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../payments/domain/payment_labels.dart';
import '../../transactions/presentation/transactions_page.dart';
import 'collections_page.dart';

class NewCollectionPage extends ConsumerStatefulWidget {
  const NewCollectionPage({super.key});

  @override
  ConsumerState<NewCollectionPage> createState() => _NewCollectionPageState();
}

class _NewCollectionPageState extends ConsumerState<NewCollectionPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  String? _assignmentId;
  String? _establishmentId;
  String? _obligationId;
  String _method = 'cash';
  String _outcome = 'contacted';
  bool _includeVisitLocation = false;
  bool _visitOnly = false;
  bool _offlineOptions = false;
  List<_AssignmentOption> _assignments = [];
  List<_EstablishmentOption> _establishments = [];
  List<_ObligationOption> _obligations = [];
  bool _loadingOptions = true;
  bool _busy = false;
  String? _error;
  String? _pendingPaymentId;
  String? _queuedOperationId;
  bool _submittedVisitOnly = false;
  late final String _idempotencyKey = _newIdempotencyKey();

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadAssignments);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  SupabaseClient? get _client => ref.read(supabaseClientProvider);

  Future<void> _loadAssignments() async {
    final userId = ref.read(authRepositoryProvider)?.currentUser?.id;
    final store = ref.read(offlineStoreProvider);
    try {
      final profile = await ref.read(currentProfileProvider.future);
      if (_client == null || profile?.organizationId == null) {
        throw StateError('Online profile unavailable');
      }
      final assignmentRows = await _client!
          .from('mission_assignments')
          .select('id, mission_id')
          .eq('organization_id', profile!.organizationId!)
          .eq('user_id', profile.id);
      final assignments = <_AssignmentOption>[];
      for (final row in assignmentRows) {
        final mission = await _client!
            .from('missions')
            .select('id, title, zone_id, zones(name)')
            .eq('id', row['mission_id'] as String)
            .maybeSingle();
        if (mission == null) continue;
        final zone = mission['zones'] as Map<String, dynamic>?;
        assignments.add(
          _AssignmentOption(
            id: row['id'] as String,
            missionId: mission['id'] as String,
            title: mission['title'] as String,
            zoneId: mission['zone_id'] as String,
            zoneName: zone?['name'] as String? ?? 'Zone',
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _assignments = assignments;
        _loadingOptions = false;
      });
    } catch (_) {
      if (userId == null || store == null) {
        if (mounted) {
          setState(() {
            _loadingOptions = false;
            _error = 'Aucune session ni donnée locale disponible.';
          });
        }
        return;
      }
      final cached = await store.cachedRecordsForUser(
        category: 'missions',
        userId: userId,
      );
      final assignments = cached
          .where((row) => row['assignment_id'] is String)
          .map(
            (row) => _AssignmentOption(
              id: row['assignment_id'] as String,
              missionId: row['id'] as String,
              title: row['title'] as String? ?? 'Mission',
              zoneId: row['zone_id'] as String? ?? '',
              zoneName: row['zone_name'] as String? ?? 'Zone',
            ),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _assignments = assignments;
        _offlineOptions = true;
        _loadingOptions = false;
        _error = assignments.isEmpty
            ? 'Aucune mission disponible sans connexion. Reconnectez-vous pour actualiser vos missions.'
            : null;
        _visitOnly = true;
      });
    }
  }

  Future<void> _selectAssignment(String? id) async {
    setState(() {
      _assignmentId = id;
      _establishmentId = null;
      _obligationId = null;
      _establishments = [];
      _obligations = [];
      _error = null;
      _busy = true;
    });
    final assignment = _assignments.where((item) => item.id == id).firstOrNull;
    if (assignment == null) {
      setState(() => _busy = false);
      return;
    }
    if (_offlineOptions) {
      final userId = ref.read(authRepositoryProvider)?.currentUser?.id;
      final store = ref.read(offlineStoreProvider);
      if (userId == null || store == null) {
        setState(() {
          _busy = false;
          _error =
              'Les données de vos missions ne sont pas disponibles sur ce téléphone.';
        });
        return;
      }
      final cached = await store.cachedRecordsForUser(
        category: 'establishments',
        userId: userId,
      );
      if (!mounted) return;
      setState(() {
        _establishments = cached
            .where((row) => row['zone_id'] == assignment.zoneId)
            .map(_EstablishmentOption.fromMap)
            .toList();
        _busy = false;
        _error = _establishments.isEmpty
            ? 'Aucun établissement disponible sans connexion pour cette zone.'
            : null;
      });
      return;
    }
    try {
      final rows = await _client!
          .from('establishments')
          .select('id, name, address')
          .eq(
            'organization_id',
            (await ref.read(currentProfileProvider.future))!.organizationId!,
          )
          .eq('zone_id', assignment.zoneId)
          .eq('is_active', true)
          .order('name')
          .limit(100);
      if (mounted)
        setState(
          () =>
              _establishments = rows.map(_EstablishmentOption.fromMap).toList(),
        );
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Établissements de la mission indisponibles.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectEstablishment(String? id) async {
    setState(() {
      _establishmentId = id;
      _obligationId = null;
      _obligations = [];
      _error = null;
      _busy = true;
    });
    if (id == null) {
      setState(() => _busy = false);
      return;
    }
    if (_visitOnly || _offlineOptions) {
      setState(() {
        _obligations = [];
        _obligationId = null;
        _busy = false;
      });
      return;
    }
    try {
      final profile = await ref.read(currentProfileProvider.future);
      final rows = await _client!
          .from('financial_obligations')
          .select('id, amount_due, amount_paid, currency_code, due_date')
          .eq('organization_id', profile!.organizationId!)
          .eq('establishment_id', id)
          .inFilter('status', ['open', 'partial'])
          .order('due_date')
          .limit(100);
      if (mounted)
        setState(
          () => _obligations = rows.map(_ObligationOption.fromMap).toList(),
        );
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Obligations indisponibles pour cet établissement.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;

    final userId = ref.read(authRepositoryProvider)?.currentUser?.id;

    final assignment = _assignments
        .where((item) => item.id == _assignmentId)
        .firstOrNull;
    final obligation = _obligations
        .where((item) => item.id == _obligationId)
        .firstOrNull;
    if (userId == null ||
        assignment == null ||
        (!_visitOnly && obligation == null))
      return;
    final store = ref.read(offlineStoreProvider);
    if (store == null) {
      setState(
        () => _error =
            'Le stockage sécurisé local est indisponible. Aucune opération n’a été enregistrée.',
      );
      return;
    }
    final operationType = _visitOnly
        ? 'collection_visit'
        : 'collection_payment_request';
    final resourceRef = _visitOnly ? _establishmentId! : obligation!.id;
    if (await store.hasUnresolvedOperation(
      ownerUserId: userId,
      operationType: operationType,
      resourceRef: resourceRef,
    )) {
      setState(
        () => _error =
            'Une opération pour cette ressource est déjà en attente ou nécessite une intervention.',
      );
      return;
    }

    final amount = _visitOnly ? null : int.parse(_amountController.text.trim());
    final establishment = _establishments
        .where((item) => item.id == _establishmentId)
        .firstOrNull;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _visitOnly ? 'Vérifier la visite' : 'Vérifier la demande de paiement',
        ),
        content: Text(
          _visitOnly
              ? '${establishment?.name ?? 'Établissement'}\n${_outcomeLabel(_outcome)}\nAucun paiement ni reçu ne sera créé.'
              : '${establishment?.name ?? 'Établissement'}\n'
                    '${CurrencyFormatter.formatCfa(amount!)} · ${paymentMethodLabel(_method)}\n'
                    'Solde restant : ${CurrencyFormatter.formatCfa(obligation!.remaining)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Corriger'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Transmettre'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    VisitLocationResult? visitLocation;
    if (_includeVisitLocation) {
      final captured = await const VisitLocationService().captureForVisit();
      if (!captured.hasUsableLocation) {
        if (!mounted) return;
        final continueWithoutGps = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Position indisponible'),
            content: Text(_locationStatusMessage(captured.status)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continuer sans GPS'),
              ),
            ],
          ),
        );
        if (continueWithoutGps != true || !mounted) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      } else {
        visitLocation = captured;
      }
    }

    try {
      final operationId = await store.enqueue(
        ownerUserId: userId,
        operationType: operationType,
        resourceRef: resourceRef,
        idempotencyKey: _idempotencyKey,
        payload: {
          'assignment_id': assignment.id,
          'establishment_id': _establishmentId,
          if (!_visitOnly) 'obligation_id': obligation!.id,
          if (!_visitOnly) 'amount': amount,
          if (!_visitOnly) 'method': _method,
          'outcome': _outcome,
          'visited_at': DateTime.now().toUtc().toIso8601String(),
          'notes': _notesController.text.trim().isEmpty
              ? null
              : _notesController.text.trim(),
          'latitude': visitLocation?.latitude,
          'longitude': visitLocation?.longitude,
          'accuracy_m': visitLocation?.accuracyMeters,
          'location_captured_at': visitLocation?.capturedAt
              ?.toUtc()
              .toIso8601String(),
        },
      );
      ref.invalidate(collectorCollectionsProvider);
      ref.invalidate(collectorTransactionsProvider);
      final syncManager = ref.read(offlineSyncManagerProvider);
      await syncManager?.syncNow();
      final savedOperation = await store.operationById(
        operationId,
        ownerUserId: userId,
      );
      if (!mounted) return;
      setState(() {
        _submittedVisitOnly = _visitOnly;
        if (savedOperation?.state == OutboxState.synced) {
          if (_visitOnly) {
            _pendingPaymentId = savedOperation?.resourceRef;
            _submittedVisitOnly = true;
          } else {
            _pendingPaymentId = savedOperation?.resourceRef;
          }
        } else {
          _queuedOperationId = operationId;
        }
      });
    } on OfflineOperationAlreadyPending {
      if (mounted)
        setState(
          () =>
              _error = 'Cette opération est déjà présente dans la file locale.',
        );
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = _friendlyDatabaseError(error));
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Envoi impossible. Vérifiez la connexion puis réessayez.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _newIdempotencyKey() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  String _friendlyDatabaseError(PostgrestException error) {
    if (error.code == '42501')
      return 'Cette action n’est pas autorisée pour votre compte.';
    if (error.code == '23505') {
      return error.message.contains('similar pending payment')
          ? 'Un paiement identique vient déjà d’être enregistré pour cette obligation. Vérifiez vos transactions avant de recommencer.'
          : 'Cette opération existe déjà. Actualisez l’écran.';
    }
    return 'Impossible d’enregistrer l’opération. Vérifiez les informations puis réessayez.';
  }

  @override
  Widget build(BuildContext context) {
    // Affichage seulement : record_collection_payment_request revérifie
    // payment.record côté serveur.
    final paymentAllowed =
        ref
            .watch(currentPermissionsProvider)
            .valueOrNull
            ?.contains('payment.record') ??
        false;
    if (!paymentAllowed) _visitOnly = true;
    if (_pendingPaymentId != null || _queuedOperationId != null) {
      final isQueued = _queuedOperationId != null;
      final isVisitOnly = _submittedVisitOnly;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            isQueued
                ? 'En attente de synchronisation'
                : isVisitOnly
                ? 'Visite transmise'
                : 'Demande transmise',
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isQueued ? Icons.cloud_upload_outlined : Icons.hourglass_top,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  isQueued
                      ? 'Opération conservée sur cet appareil'
                      : isVisitOnly
                      ? 'Visite enregistrée'
                      : 'Paiement en attente de confirmation',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  isQueued
                      ? isVisitOnly
                            ? 'La visite sera transmise au retour du réseau. Aucun paiement n’est créé.'
                            : 'La demande sera envoyée au retour du réseau. Aucun paiement n’est confirmé.'
                      : isVisitOnly
                      ? 'Cette visite ne crée aucun paiement ni reçu.'
                      : 'Le paiement est enregistré et attend sa confirmation. Le reçu sera disponible une fois le paiement confirmé.',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  isQueued
                      ? 'Envoi automatique dès le retour du réseau'
                      : 'Référence · ${_pendingPaymentId!.substring(0, 8).toUpperCase()}',
                ),
                const SizedBox(height: 20),
                if (isQueued)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await ref
                          .read(offlineSyncManagerProvider)
                          ?.syncNow(forceRetry: true);
                      final userId = ref
                          .read(authRepositoryProvider)
                          ?.currentUser
                          ?.id;
                      final operation = userId == null
                          ? null
                          : await ref
                                .read(offlineStoreProvider)
                                ?.operationById(
                                  _queuedOperationId!,
                                  ownerUserId: userId,
                                );
                      if (!mounted) return;
                      if (operation?.state == OutboxState.synced) {
                        setState(() {
                          _pendingPaymentId = operation?.resourceRef;
                          _queuedOperationId = null;
                        });
                      }
                    },
                    icon: const Icon(Icons.sync),
                    label: const Text('Réessayer maintenant'),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Terminer'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle collecte')),
      body: _loadingOptions
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const LinearProgressIndicator(value: 1),
                    const SizedBox(height: 16),
                    Text(
                      'Visite et paiement',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sélectionnez uniquement une mission qui vous est affectée.',
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: [
                        const ButtonSegment(
                          value: true,
                          label: Text('Visite seule'),
                        ),
                        ButtonSegment(
                          value: false,
                          label: const Text('Avec demande de paiement'),
                          enabled: !_offlineOptions && paymentAllowed,
                        ),
                      ],
                      selected: {_visitOnly},
                      onSelectionChanged: (selection) {
                        final visitOnly = selection.first;
                        final establishmentId = _establishmentId;
                        setState(() {
                          _visitOnly = visitOnly;
                          _error = null;
                          if (visitOnly) {
                            _obligationId = null;
                            _amountController.clear();
                          }
                        });
                        if (!visitOnly &&
                            establishmentId != null &&
                            !_offlineOptions) {
                          _selectEstablishment(establishmentId);
                        }
                      },
                    ),
                    if (!paymentAllowed && !_offlineOptions) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Votre compte ne permet pas d’enregistrer un paiement. Vous pouvez déclarer la visite.',
                      ),
                    ],
                    if (_offlineOptions) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Sans connexion, seule la visite peut être enregistrée. Les paiements nécessitent Internet.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _assignmentId,
                      decoration: const InputDecoration(
                        labelText: 'Mission affectée',
                      ),
                      items: _assignments
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(
                                '${item.title} · ${item.zoneName}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _busy ? null : _selectAssignment,
                      validator: (value) =>
                          value == null ? 'Choisissez une mission.' : null,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _establishmentId,
                      decoration: const InputDecoration(
                        labelText: 'Établissement',
                      ),
                      items: _establishments
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _busy || _assignmentId == null
                          ? null
                          : _selectEstablishment,
                      validator: (value) =>
                          value == null ? 'Choisissez un établissement.' : null,
                    ),
                    const SizedBox(height: 12),
                    if (_visitOnly)
                      DropdownButtonFormField<String>(
                        initialValue: _outcome,
                        decoration: const InputDecoration(
                          labelText: 'Résultat de visite',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'contacted',
                            child: Text('Contact effectué'),
                          ),
                          DropdownMenuItem(
                            value: 'unavailable',
                            child: Text('Contribuable absent'),
                          ),
                          DropdownMenuItem(
                            value: 'refused',
                            child: Text('Refus'),
                          ),
                          DropdownMenuItem(
                            value: 'follow_up',
                            child: Text('Suivi à prévoir'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(
                                () => _outcome = value ?? 'contacted',
                              ),
                      )
                    else ...[
                      DropdownButtonFormField<String>(
                        initialValue: _obligationId,
                        decoration: const InputDecoration(
                          labelText: 'Obligation ouverte',
                        ),
                        items: _obligations
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  '${CurrencyFormatter.formatCfa(item.remaining)} · échéance ${item.dueDate}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: _busy || _establishmentId == null
                            ? null
                            : (value) => setState(() => _obligationId = value),
                        validator: (value) => value == null
                            ? 'Choisissez une obligation ouverte.'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: false,
                        ),
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Montant déclaré (FCFA)',
                        ),
                        validator: (value) {
                          final amount = int.tryParse(value?.trim() ?? '');
                          if (amount == null || amount <= 0)
                            return 'Saisissez un montant entier supérieur à zéro.';
                          final obligation = _obligations
                              .where((item) => item.id == _obligationId)
                              .firstOrNull;
                          if (obligation != null &&
                              amount > obligation.remaining) {
                            return 'Le montant dépasse le solde de ${CurrencyFormatter.formatCfa(obligation.remaining)}.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _method,
                        decoration: const InputDecoration(
                          labelText: 'Mode déclaré',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'cash',
                            child: Text('Espèces'),
                          ),
                          DropdownMenuItem(
                            value: 'mobile_money',
                            child: Text('Mobile Money'),
                          ),
                          DropdownMenuItem(
                            value: 'bank_transfer',
                            child: Text('Virement'),
                          ),
                          DropdownMenuItem(value: 'card', child: Text('Carte')),
                          DropdownMenuItem(
                            value: 'other',
                            child: Text('Autre moyen autorisé'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) =>
                                  setState(() => _method = value ?? 'cash'),
                      ),
                    ],
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _includeVisitLocation,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _includeVisitLocation = value),
                      title: const Text('Ajouter ma position à la visite'),
                      subtitle: const Text(
                        'Facultatif. Sert à documenter la visite; la position ne prouve pas un paiement.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _notesController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Note de visite (facultatif)',
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _busy || (!_visitOnly && _obligationId == null)
                          ? null
                          : _submit,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(
                        _busy
                            ? 'Enregistrement…'
                            : _visitOnly
                            ? 'Enregistrer la visite'
                            : 'Vérifier la demande',
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _AssignmentOption {
  const _AssignmentOption({
    required this.id,
    required this.missionId,
    required this.title,
    required this.zoneId,
    required this.zoneName,
  });

  final String id;
  final String missionId;
  final String title;
  final String zoneId;
  final String zoneName;
}

class _EstablishmentOption {
  const _EstablishmentOption({required this.id, required this.name});

  final String id;
  final String name;

  factory _EstablishmentOption.fromMap(Map<String, dynamic> row) =>
      _EstablishmentOption(
        id: row['id'] as String,
        name: row['name'] as String,
      );
}

class _ObligationOption {
  const _ObligationOption({
    required this.id,
    required this.remaining,
    required this.dueDate,
  });

  final String id;
  final int remaining;
  final String dueDate;

  factory _ObligationOption.fromMap(Map<String, dynamic> row) =>
      _ObligationOption(
        id: row['id'] as String,
        remaining:
            (row['amount_due'] as num).toInt() -
            (row['amount_paid'] as num).toInt(),
        dueDate: row['due_date'] as String,
      );
}

String _outcomeLabel(String value) => switch (value) {
  'contacted' => 'Contact effectué',
  'unavailable' => 'Contribuable absent',
  'refused' => 'Refus',
  _ => 'Suivi à prévoir',
};

String _locationStatusMessage(VisitLocationStatus status) => switch (status) {
  VisitLocationStatus.permissionDenied =>
    'La permission de localisation a été refusée.',
  VisitLocationStatus.serviceDisabled =>
    'Le GPS est désactivé sur cet appareil.',
  VisitLocationStatus.insufficientAccuracy =>
    'La précision GPS est insuffisante pour enregistrer cette position.',
  VisitLocationStatus.unavailable =>
    'La position GPS est temporairement indisponible.',
  VisitLocationStatus.captured => 'Position capturée.',
};
