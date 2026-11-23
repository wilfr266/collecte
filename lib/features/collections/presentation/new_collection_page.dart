import 'dart:convert';
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
import '../domain/payment_request_form.dart';
import 'collections_page.dart';

/// Valeur de la liste « Échéance » signifiant : aucune échéance préalable.
/// Le serveur rattache alors la demande au relevé du jour du client.
const _noObligation = '';

/// Codes d'erreur (offline_sync_manager) d'un refus définitif du serveur :
/// rien n'a été enregistré, l'opération peut être corrigée puis renvoyée.
const _serverRefusals = {
  'duplicate_or_idempotency_conflict',
  'permission_denied',
  'server_validation_conflict',
};

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
  bool _visitOnly = true;
  bool _offlineOptions = false;
  List<_AssignmentOption> _assignments = [];
  List<_EstablishmentOption> _establishments = [];
  List<_ObligationOption> _obligations = [];
  bool _loadingOptions = true;
  bool _loadingDetails = false;
  bool _busy = false;
  String? _error;

  // Résultat : référence serveur (opération synchronisée) ou opération locale.
  String? _serverReference;
  String? _queuedOperationId;
  bool _submittedVisitOnly = false;
  _Recap? _submittedRecap;
  _RequestOverview? _overview;

  // Une clé par contenu de demande : une relance identique réutilise la clé
  // (aucun doublon côté serveur), une demande corrigée en reçoit une nouvelle.
  String _idempotencyKey = _newIdempotencyKey();
  String? _idempotencySignature;

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

  _AssignmentOption? get _assignment =>
      _assignments.where((item) => item.id == _assignmentId).firstOrNull;
  _EstablishmentOption? get _establishment =>
      _establishments.where((item) => item.id == _establishmentId).firstOrNull;
  _ObligationOption? get _obligation =>
      _obligations.where((item) => item.id == _obligationId).firstOrNull;

  bool _effectiveVisitOnly(bool paymentAllowed) =>
      _visitOnly || !paymentAllowed || _offlineOptions;

  List<String> _issues(bool paymentAllowed) =>
      _effectiveVisitOnly(paymentAllowed)
      ? visitIssues(
          assignmentId: _assignmentId,
          establishmentId: _establishmentId,
        )
      : paymentRequestIssues(
          paymentAllowed: paymentAllowed,
          online: !_offlineOptions,
          assignmentId: _assignmentId,
          establishmentId: _establishmentId,
          amountText: _amountController.text,
          method: _method,
          obligationRemaining: _obligation?.remaining,
        );

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
        _error = assignments.isEmpty
            ? 'Aucune mission ne vous est affectée. Une mission est nécessaire pour enregistrer une visite.'
            : null;
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
      _loadingDetails = true;
    });
    final assignment = _assignment;
    if (assignment == null) {
      setState(() => _loadingDetails = false);
      return;
    }
    if (_offlineOptions) {
      final userId = ref.read(authRepositoryProvider)?.currentUser?.id;
      final store = ref.read(offlineStoreProvider);
      if (userId == null || store == null) {
        setState(() {
          _loadingDetails = false;
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
        _loadingDetails = false;
        _error = _establishments.isEmpty
            ? 'Aucun établissement disponible sans connexion pour cette zone.'
            : null;
      });
      return;
    }
    try {
      final organizationId = (await ref.read(
        currentProfileProvider.future,
      ))!.organizationId!;
      final rows = await _client!
          .from('establishments')
          .select('id, name, address, taxpayer_id')
          .eq('organization_id', organizationId)
          .eq('zone_id', assignment.zoneId)
          .eq('is_active', true)
          .order('name')
          .limit(100);
      var establishments = rows.map(_EstablishmentOption.fromMap).toList();
      // Nom et téléphone du client : complément d'affichage. Le serveur
      // retrouve lui-même le client à partir de l'établissement.
      final taxpayerIds = {
        for (final item in establishments)
          if (item.taxpayerId != null) item.taxpayerId!,
      }.toList();
      if (taxpayerIds.isNotEmpty) {
        try {
          final taxpayers = await _client!
              .from('taxpayers')
              .select('id, legal_name, phone')
              .eq('organization_id', organizationId)
              .inFilter('id', taxpayerIds);
          final byId = {for (final row in taxpayers) row['id'] as String: row};
          establishments = [
            for (final item in establishments)
              item.withTaxpayer(byId[item.taxpayerId]),
          ];
        } catch (_) {
          // Affichage sans nom de client ; l'enregistrement reste possible.
        }
      }
      if (!mounted) return;
      setState(() {
        _establishments = establishments;
        _error = establishments.isEmpty
            ? 'Aucun établissement actif dans la zone de cette mission.'
            : null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Établissements de la mission indisponibles.');
      }
    } finally {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  Future<void> _selectEstablishment(String? id) async {
    setState(() {
      _establishmentId = id;
      _obligationId = null;
      _obligations = [];
      _error = null;
    });
    if (id == null || _visitOnly || _offlineOptions) return;
    setState(() => _loadingDetails = true);
    try {
      final profile = await ref.read(currentProfileProvider.future);
      final organizationId = profile!.organizationId!;
      final rows = await _client!
          .from('financial_obligations')
          .select('id, amount_due, amount_paid, due_date, tax_type_id')
          .eq('organization_id', organizationId)
          .eq('establishment_id', id)
          .inFilter('status', ['open', 'partial'])
          .order('due_date')
          .limit(100);
      // Les relevés « Encaissement » du jour sont créés par le serveur pour les
      // demandes sans échéance : ils ne se choisissent pas.
      final taxTypes = await _client!
          .from('tax_types')
          .select('id, code, label')
          .eq('organization_id', organizationId);
      final typeById = {for (final row in taxTypes) row['id'] as String: row};
      final obligations = [
        for (final row in rows)
          if (typeById[row['tax_type_id']]?['code'] != 'encaissement')
            _ObligationOption.fromMap(
              row,
              label: typeById[row['tax_type_id']]?['label'] as String?,
            ),
      ].where((item) => item.remaining > 0).toList();
      if (mounted && _establishmentId == id) {
        setState(() => _obligations = obligations);
      }
    } catch (_) {
      // Sans liste d'échéances, la demande reste possible sans échéance.
      if (mounted) {
        setState(
          () => _error =
              'Échéances indisponibles : la demande sera enregistrée sans échéance.',
        );
      }
    } finally {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  Future<void> _review({required bool paymentAllowed}) async {
    if (_busy || _loadingDetails) return;
    final visitOnly = _effectiveVisitOnly(paymentAllowed);
    final formValid = _formKey.currentState!.validate();
    if (!formValid || _issues(paymentAllowed).isNotEmpty) return;
    // Verrou posé avant tout `await` : un double appui n'ouvre qu'un seul
    // récapitulatif et ne produit qu'un seul envoi.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _reviewAndSubmit(visitOnly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewAndSubmit(bool visitOnly) async {
    final userId = ref.read(authRepositoryProvider)?.currentUser?.id;
    final assignment = _assignment;
    final establishment = _establishment;
    final obligation = visitOnly ? null : _obligation;
    if (userId == null || assignment == null || establishment == null) {
      setState(() => _error = 'Session expirée. Reconnectez-vous.');
      return;
    }
    final store = ref.read(offlineStoreProvider);
    if (store == null) {
      setState(
        () => _error =
            'Le stockage sécurisé local est indisponible. Aucune opération n’a été enregistrée.',
      );
      return;
    }
    final operationType = visitOnly
        ? 'collection_visit'
        : 'collection_payment_request';
    final resourceRef = visitOnly
        ? establishment.id
        : obligation?.id ?? 'payment:${establishment.id}';
    if (await store.hasUnresolvedOperation(
      ownerUserId: userId,
      operationType: operationType,
      resourceRef: resourceRef,
    )) {
      setState(
        () => _error = visitOnly
            ? 'Une visite pour ce client est déjà en attente d’envoi sur ce téléphone.'
            : 'Une demande pour ce client est déjà en attente d’envoi ou bloquée sur ce téléphone. Consultez l’écran « Hors ligne » avant d’en créer une autre.',
      );
      return;
    }

    final amount = visitOnly
        ? null
        : parsePaymentAmount(_amountController.text);
    final notes = _notesController.text.trim();
    final recap = _Recap(
      visitOnly: visitOnly,
      assignment: assignment,
      establishment: establishment,
      obligation: obligation,
      amount: amount,
      method: _method,
      outcome: _outcome,
      notes: notes.isEmpty ? null : notes,
      withLocation: _includeVisitLocation,
      at: DateTime.now(),
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecapDialog(recap: recap),
    );
    // « Modifier » : retour au formulaire, toutes les saisies sont conservées.
    if (confirmed != true || !mounted) return;

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
        if (continueWithoutGps != true || !mounted) return;
      } else {
        visitLocation = captured;
      }
    }

    final content = <String, dynamic>{
      'assignment_id': assignment.id,
      'establishment_id': establishment.id,
      if (!visitOnly) 'obligation_id': obligation?.id,
      if (!visitOnly) 'amount': amount,
      if (!visitOnly) 'method': _method,
      'outcome': _outcome,
      'notes': recap.notes,
    };
    final signature = jsonEncode({'type': operationType, ...content});
    if (_idempotencySignature != signature) {
      _idempotencyKey = _newIdempotencyKey();
      _idempotencySignature = signature;
    }

    String? operationId;
    try {
      operationId = await store.enqueue(
        ownerUserId: userId,
        operationType: operationType,
        resourceRef: resourceRef,
        idempotencyKey: _idempotencyKey,
        payload: {
          ...content,
          'visited_at': recap.at.toUtc().toIso8601String(),
          'latitude': visitLocation?.latitude,
          'longitude': visitLocation?.longitude,
          'accuracy_m': visitLocation?.accuracyMeters,
          'location_captured_at': visitLocation?.capturedAt
              ?.toUtc()
              .toIso8601String(),
        },
      );
      _submittedVisitOnly = visitOnly;
      _submittedRecap = recap;
      await _syncUntilSettled(store, userId, operationId);
      await _applyOutcome(store, userId, operationId);
    } on OfflineOperationAlreadyPending {
      if (mounted) {
        setState(
          () =>
              _error = 'Cette opération est déjà présente dans la file locale.',
        );
      }
    } catch (_) {
      if (!mounted) return;
      if (operationId != null) {
        // Déjà dans la file locale : elle sera renvoyée avec la même clé,
        // sans doublon. Aucun succès n'est affiché.
        setState(() => _queuedOperationId = operationId);
      } else {
        setState(
          () => _error =
              'Enregistrement local impossible. Aucune demande n’a été envoyée ; réessayez.',
        );
      }
    } finally {
      if (mounted) {
        ref.invalidate(collectorCollectionsProvider);
        ref.invalidate(collectorTransactionsProvider);
      }
    }
  }

  /// Lance la synchronisation et attend brièvement qu'elle traite
  /// l'opération (une synchronisation de fond peut déjà être en cours).
  Future<void> _syncUntilSettled(
    OfflineStore store,
    String userId,
    String operationId, {
    bool forceRetry = false,
  }) async {
    final sync = ref.read(offlineSyncManagerProvider);
    if (sync == null) return;
    for (var attempt = 0; attempt < 8; attempt++) {
      await sync.syncNow(forceRetry: forceRetry);
      final operation = await store.operationById(
        operationId,
        ownerUserId: userId,
      );
      final inFlight =
          operation != null &&
          (operation.state == OutboxState.pending ||
              operation.state == OutboxState.syncing);
      if (!inFlight || sync.status == SyncStatus.offline) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// N'affiche un succès que si le serveur a réellement enregistré
  /// l'opération (état `synced` avec sa référence).
  Future<void> _applyOutcome(
    OfflineStore store,
    String userId,
    String operationId,
  ) async {
    final operation = await store.operationById(
      operationId,
      ownerUserId: userId,
    );
    if (!mounted) return;
    if (operation?.state == OutboxState.synced) {
      final reference = operation!.resourceRef;
      final overview = _submittedVisitOnly
          ? null
          : await _loadOverview(reference);
      if (!mounted) return;
      setState(() {
        _serverReference = reference;
        _overview = overview;
        _queuedOperationId = null;
      });
      return;
    }
    if (operation?.state == OutboxState.needsAttention &&
        _serverRefusals.contains(operation!.technicalError)) {
      // Refus définitif : rien n'est enregistré. Retour au formulaire, saisies
      // conservées, pour corriger et renvoyer.
      await store.dismissRejected(operation.id, ownerUserId: userId);
      if (!mounted) return;
      setState(() {
        _queuedOperationId = null;
        _error = _refusalMessage(operation.technicalError);
      });
      return;
    }
    setState(() => _queuedOperationId = operationId);
  }

  Future<_RequestOverview?> _loadOverview(String paymentId) async {
    try {
      final rows = await _client!.rpc(
        'payment_request_overview',
        params: {'p_payment_id': paymentId},
      );
      final list = (rows as List<dynamic>).cast<Map<String, dynamic>>();
      return list.isEmpty ? null : _RequestOverview.fromRow(list.first);
    } catch (_) {
      // Récapitulatif serveur indisponible : la demande reste enregistrée.
      return null;
    }
  }

  Future<void> _retryQueued() async {
    final userId = ref.read(authRepositoryProvider)?.currentUser?.id;
    final store = ref.read(offlineStoreProvider);
    final operationId = _queuedOperationId;
    if (userId == null || store == null || operationId == null) return;
    setState(() => _busy = true);
    try {
      await _syncUntilSettled(store, userId, operationId, forceRetry: true);
      await _applyOutcome(store, userId, operationId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _newIdempotencyKey() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  String _refusalMessage(String? code) => switch (code) {
    'permission_denied' =>
      'Le serveur a refusé la demande : ce client ne fait pas partie d’une mission active qui vous est affectée, ou votre compte n’a pas ce droit. Rien n’a été enregistré.',
    'duplicate_or_idempotency_conflict' =>
      'Une demande identique vient déjà d’être enregistrée pour ce client. Vérifiez vos transactions avant de recommencer.',
    _ =>
      'Le serveur a refusé les informations (montant ou échéance). Rien n’a été enregistré : corrigez puis réessayez.',
  };

  @override
  Widget build(BuildContext context) {
    // Affichage seulement : record_collection_payment_request revérifie
    // payment.record côté serveur.
    final permissions = ref.watch(currentPermissionsProvider);
    final paymentAllowed =
        permissions.valueOrNull?.contains('payment.record') ?? false;
    final visitOnly = _effectiveVisitOnly(paymentAllowed);

    if (_serverReference != null || _queuedOperationId != null) {
      return _buildResult(context);
    }

    final issues = _issues(paymentAllowed);
    final canReview =
        !_busy && !_loadingDetails && !permissions.isLoading && issues.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle visite')),
      body: _loadingOptions
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
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
                      selected: {visitOnly},
                      onSelectionChanged: _busy
                          ? null
                          : (selection) {
                              final nextVisitOnly = selection.first;
                              final establishmentId = _establishmentId;
                              setState(() {
                                _visitOnly = nextVisitOnly;
                                _error = null;
                                if (nextVisitOnly) {
                                  _obligationId = null;
                                  _obligations = [];
                                }
                              });
                              if (!nextVisitOnly && establishmentId != null) {
                                _selectEstablishment(establishmentId);
                              }
                            },
                    ),
                    if (permissions.isLoading && !_offlineOptions) ...[
                      const SizedBox(height: 8),
                      const Text('Vérification des droits de votre compte…'),
                    ] else if (!paymentAllowed && !_offlineOptions) ...[
                      const SizedBox(height: 8),
                      Text(
                        permissions.hasError
                            ? 'Droits de votre compte indisponibles : seule la visite peut être déclarée. Réessayez avec une meilleure connexion.'
                            : 'Votre compte ne permet pas d’enregistrer un paiement. Vous pouvez déclarer la visite.',
                      ),
                    ],
                    if (_offlineOptions) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Sans connexion, seule la visite peut être enregistrée. Les demandes de paiement nécessitent Internet.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _assignmentId,
                      isExpanded: true,
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
                      onChanged: _busy || _loadingDetails
                          ? null
                          : _selectAssignment,
                      validator: (value) =>
                          value == null ? 'Choisissez une mission.' : null,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _establishmentId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Client (établissement)',
                        helperText: _assignmentId == null
                            ? 'Choisissez d’abord une mission.'
                            : null,
                      ),
                      items: _establishments
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.id,
                              child: Text(
                                item.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged:
                          _busy || _loadingDetails || _assignmentId == null
                          ? null
                          : _selectEstablishment,
                      validator: (value) =>
                          value == null ? 'Choisissez un client.' : null,
                    ),
                    const SizedBox(height: 12),
                    if (visitOnly)
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
                      if (_obligations.isNotEmpty) ...[
                        DropdownButtonFormField<String>(
                          initialValue: _obligationId ?? _noObligation,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Échéance (facultatif)',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: _noObligation,
                              child: Text('Aucune — nouvelle demande'),
                            ),
                            for (final item in _obligations)
                              DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  item.displayName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(
                                  () => _obligationId = value == _noObligation
                                      ? null
                                      : value,
                                ),
                        ),
                        const SizedBox(height: 12),
                      ] else if (_establishmentId != null &&
                          !_loadingDetails) ...[
                        Text(
                          'Aucune échéance ouverte pour ce client : la demande sera enregistrée sur son relevé du jour.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _amountController,
                        enabled: !_busy,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: false,
                        ),
                        textInputAction: TextInputAction.next,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        decoration: const InputDecoration(
                          labelText: 'Montant demandé (FCFA)',
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: (value) => paymentAmountError(
                          value ?? '',
                          obligationRemaining: _obligation?.remaining,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _method,
                        decoration: const InputDecoration(
                          labelText: 'Mode de paiement prévu',
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
                      enabled: !_busy,
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
                      onPressed: canReview
                          ? () => _review(paymentAllowed: paymentAllowed)
                          : null,
                      icon: _busy || _loadingDetails
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined),
                      label: Text(
                        _busy
                            ? 'Enregistrement…'
                            : _loadingDetails
                            ? 'Chargement…'
                            : visitOnly
                            ? 'Vérifier la visite'
                            : 'Vérifier la demande',
                      ),
                    ),
                    if (!_busy && !_loadingDetails && issues.isNotEmpty)
                      _MissingFields(issues: issues),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildResult(BuildContext context) {
    final isQueued = _queuedOperationId != null;
    final isVisitOnly = _submittedVisitOnly;
    final recap = _submittedRecap;
    final overview = _overview;
    final theme = Theme.of(context);

    final String title;
    final String headline;
    final String explanation;
    if (isQueued) {
      title = 'Envoi en attente';
      headline = 'Pas encore reçue par le serveur';
      explanation = isVisitOnly
          ? 'La visite est conservée sur ce téléphone et sera envoyée automatiquement au retour du réseau. Aucun paiement n’est créé.'
          : 'La demande est conservée sur ce téléphone et sera envoyée automatiquement au retour du réseau. Elle n’est pas encore enregistrée : aucun paiement n’est confirmé et le client n’a pas encore été notifié.';
    } else if (isVisitOnly) {
      title = 'Visite transmise';
      headline = 'Visite enregistrée';
      explanation = 'Cette visite ne crée aucun paiement ni reçu.';
    } else {
      title = 'Demande transmise';
      headline = 'Demande de paiement enregistrée';
      explanation =
          'La demande est enregistrée et reste « en attente » jusqu’à la confirmation du paiement. Aucun encaissement n’est comptabilisé tant qu’il n’est pas confirmé ; le reçu sera disponible à ce moment-là.';
    }

    final notification = isQueued || isVisitOnly
        ? null
        : overview == null
        ? 'État de la notification du client indisponible pour le moment.'
        : overview.notifiedClients > 0
        ? 'Le client a été notifié dans son application Terenza '
              '(${overview.notifiedClients} compte${overview.notifiedClients > 1 ? 's' : ''}).'
        : 'Aucun compte client Terenza n’est lié à ce client : aucune notification n’a pu lui être adressée.';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              isQueued ? Icons.cloud_upload_outlined : Icons.hourglass_top,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              headline,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(explanation, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (recap != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _RecapLine(
                        'Client',
                        overview?.taxpayerName ??
                            recap.establishment.taxpayerName ??
                            recap.establishment.name,
                      ),
                      _RecapLine('Établissement', recap.establishment.name),
                      if (!isVisitOnly) ...[
                        _RecapLine(
                          'Montant demandé',
                          CurrencyFormatter.formatCfa(
                            overview?.amount ?? recap.amount!,
                          ),
                        ),
                        _RecapLine(
                          'Mode prévu',
                          paymentMethodLabel(recap.method),
                        ),
                        if (!isQueued)
                          _RecapLine(
                            'Statut',
                            overview?.status == 'pending' || overview == null
                                ? 'En attente de paiement'
                                : overview.status,
                          ),
                      ] else
                        _RecapLine('Résultat', _outcomeLabel(recap.outcome)),
                      _RecapLine(
                        'Date et heure',
                        _formatDateTime(overview?.createdAt ?? recap.at),
                      ),
                      if (_serverReference != null)
                        _RecapLine(
                          'Référence',
                          _serverReference!.substring(0, 8).toUpperCase(),
                        ),
                    ],
                  ),
                ),
              ),
            if (notification != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.notifications_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(notification)),
                ],
              ),
            ],
            const SizedBox(height: 20),
            if (isQueued)
              OutlinedButton.icon(
                onPressed: _busy ? null : _retryQueued,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Réessayer maintenant'),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Terminer'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Liste de ce qui manque encore : le bouton n'est jamais grisé sans
/// explication.
class _MissingFields extends StatelessWidget {
  const _MissingFields({required this.issues});

  final List<String> issues;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pour continuer :', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(issue, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecapDialog extends StatelessWidget {
  const _RecapDialog({required this.recap});

  final _Recap recap;

  @override
  Widget build(BuildContext context) {
    final establishment = recap.establishment;
    final obligation = recap.obligation;
    return AlertDialog(
      scrollable: true,
      title: Text(
        recap.visitOnly ? 'Vérifier la visite' : 'Vérifier la demande',
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _RecapLine(
            'Client',
            establishment.taxpayerName ?? 'Client de l’établissement',
          ),
          _RecapLine('Établissement', establishment.name),
          if (establishment.address != null)
            _RecapLine('Adresse', establishment.address!),
          if (establishment.taxpayerPhone != null)
            _RecapLine('Téléphone', establishment.taxpayerPhone!),
          _RecapLine(
            'Mission',
            '${recap.assignment.title} · ${recap.assignment.zoneName}',
          ),
          if (recap.visitOnly)
            _RecapLine('Résultat', _outcomeLabel(recap.outcome))
          else ...[
            _RecapLine(
              'Montant demandé',
              CurrencyFormatter.formatCfa(recap.amount!),
            ),
            _RecapLine('Mode prévu', paymentMethodLabel(recap.method)),
            _RecapLine(
              'Échéance',
              obligation == null
                  ? 'Aucune — relevé du jour'
                  : obligation.displayName,
            ),
          ],
          _RecapLine('Date et heure', _formatDateTime(recap.at)),
          _RecapLine('Position GPS', recap.withLocation ? 'Ajoutée' : 'Non'),
          if (recap.notes != null) _RecapLine('Note', recap.notes!),
          const SizedBox(height: 12),
          Text(
            recap.visitOnly
                ? 'Aucun paiement ni reçu ne sera créé.'
                : 'La demande sera enregistrée « en attente ». Elle ne vaut pas paiement : l’encaissement ne sera comptabilisé qu’après confirmation. Le client sera notifié dans son application Terenza s’il dispose d’un compte lié.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Modifier'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            recap.visitOnly ? 'Enregistrer la visite' : 'Confirmer la demande',
          ),
        ),
      ],
    );
  }
}

class _RecapLine extends StatelessWidget {
  const _RecapLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _Recap {
  const _Recap({
    required this.visitOnly,
    required this.assignment,
    required this.establishment,
    required this.obligation,
    required this.amount,
    required this.method,
    required this.outcome,
    required this.notes,
    required this.withLocation,
    required this.at,
  });

  final bool visitOnly;
  final _AssignmentOption assignment;
  final _EstablishmentOption establishment;
  final _ObligationOption? obligation;
  final int? amount;
  final String method;
  final String outcome;
  final String? notes;
  final bool withLocation;
  final DateTime at;
}

/// Récapitulatif renvoyé par le serveur (`payment_request_overview`).
class _RequestOverview {
  const _RequestOverview({
    required this.status,
    required this.amount,
    required this.createdAt,
    required this.taxpayerName,
    required this.notifiedClients,
  });

  factory _RequestOverview.fromRow(Map<String, dynamic> row) =>
      _RequestOverview(
        status: row['payment_status'] as String,
        amount: (row['amount'] as num).toInt(),
        createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
        taxpayerName: row['taxpayer_name'] as String?,
        notifiedClients: (row['notified_clients'] as num?)?.toInt() ?? 0,
      );

  final String status;
  final int amount;
  final DateTime createdAt;
  final String? taxpayerName;
  final int notifiedClients;
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
  const _EstablishmentOption({
    required this.id,
    required this.name,
    this.address,
    this.taxpayerId,
    this.taxpayerName,
    this.taxpayerPhone,
  });

  final String id;
  final String name;
  final String? address;
  final String? taxpayerId;
  final String? taxpayerName;
  final String? taxpayerPhone;

  String get displayName => taxpayerName == null || taxpayerName == name
      ? name
      : '$name · $taxpayerName';

  factory _EstablishmentOption.fromMap(Map<String, dynamic> row) =>
      _EstablishmentOption(
        id: row['id'] as String,
        name: row['name'] as String,
        address: _nonEmpty(row['address']),
        taxpayerId: row['taxpayer_id'] as String?,
      );

  _EstablishmentOption withTaxpayer(Map<String, dynamic>? taxpayer) =>
      taxpayer == null
      ? this
      : _EstablishmentOption(
          id: id,
          name: name,
          address: address,
          taxpayerId: taxpayerId,
          taxpayerName: _nonEmpty(taxpayer['legal_name']),
          taxpayerPhone: _nonEmpty(taxpayer['phone']),
        );
}

class _ObligationOption {
  const _ObligationOption({
    required this.id,
    required this.remaining,
    required this.dueDate,
    this.label,
  });

  final String id;
  final int remaining;
  final String dueDate;
  final String? label;

  String get displayName =>
      '${label ?? 'Échéance'} · solde ${CurrencyFormatter.formatCfa(remaining)} · ${_formatDay(dueDate)}';

  factory _ObligationOption.fromMap(
    Map<String, dynamic> row, {
    String? label,
  }) => _ObligationOption(
    id: row['id'] as String,
    remaining:
        (row['amount_due'] as num).toInt() -
        (row['amount_paid'] as num).toInt(),
    dueDate: row['due_date'] as String,
    label: label,
  );
}

String? _nonEmpty(Object? value) {
  final text = (value as String?)?.trim();
  return text == null || text.isEmpty ? null : text;
}

String _two(int value) => value.toString().padLeft(2, '0');

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  return '${_two(local.day)}/${_two(local.month)}/${local.year} à '
      '${_two(local.hour)} h ${_two(local.minute)}';
}

String _formatDay(String isoDate) {
  final date = DateTime.tryParse(isoDate);
  return date == null
      ? isoDate
      : 'échéance ${_two(date.day)}/${_two(date.month)}/${date.year}';
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
