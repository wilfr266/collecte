import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../domain/payment_models.dart';

/// Accès aux encaissements. Toutes les sommes et tous les filtres sont
/// calculés par le serveur (RPC), qui vérifie aussi le périmètre de l'appelant
/// (administration, collecteur de la zone ou client lié) : rien n'est déduit
/// d'un identifiant fourni par l'application.
class PaymentsRepository {
  PaymentsRepository(this._client);

  final SupabaseClient _client;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<PaymentSummary> summary({
    required String taxpayerId,
    required DateTime month,
  }) async {
    final json = await _client.rpc(
      'payment_summary',
      params: {
        'p_month': _day(DateTime(month.year, month.month)),
        'p_taxpayer_id': taxpayerId,
      },
    );
    return PaymentSummary.fromJson(json as Map<String, dynamic>);
  }

  Future<PaymentPage> page({
    required String taxpayerId,
    required DateTime from,
    required DateTime to,
    PaymentStatusFilter status = PaymentStatusFilter.all,
    String? search,
    int limit = 30,
    int offset = 0,
  }) async {
    final rows = await _client.rpc(
      'payments_page',
      params: {
        'p_from': _day(from),
        'p_to': _day(to),
        'p_taxpayer_id': taxpayerId,
        'p_status': status.value,
        'p_search': (search?.trim().isEmpty ?? true) ? null : search!.trim(),
        'p_limit': limit,
        'p_offset': offset,
      },
    );
    final list = (rows as List<dynamic>).cast<Map<String, dynamic>>();
    return PaymentPage(
      rows: list.map(PaymentLine.fromRow).toList(),
      total: list.isEmpty
          ? 0
          : num.parse(list.first['total_count'].toString()).toInt(),
    );
  }

  /// Mois ayant au moins un paiement, du plus récent au plus ancien.
  Future<List<PaymentMonth>> months({required String taxpayerId}) async {
    final rows = await _client.rpc(
      'payment_months',
      params: {'p_taxpayer_id': taxpayerId},
    );
    return (rows as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(PaymentMonth.fromRow)
        .toList();
  }

  /// Client et mois d'un paiement (ouverture depuis une notification) ; le
  /// serveur vérifie que l'appelant y a accès.
  Future<({String taxpayerId, String taxpayerName, DateTime month})?> location(
    String paymentId,
  ) async {
    final rows = await _client.rpc(
      'payment_location',
      params: {'p_payment_id': paymentId},
    );
    final list = (rows as List<dynamic>).cast<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    return (
      taxpayerId: list.first['taxpayer_id'] as String,
      taxpayerName: list.first['taxpayer_name'] as String,
      month: DateTime.parse(list.first['month'] as String),
    );
  }

  /// Encaissement terrain : la clé d'idempotence rend la relance sans risque
  /// (réseau coupé, double appui) ; la réponse est celle du serveur.
  Future<({String status, String? receiptNumber})> record({
    required String establishmentId,
    required int amount,
    required String method,
    required String idempotencyKey,
    String? provider,
    String? providerReference,
  }) async {
    final rows = await _client.rpc(
      'record_field_payment',
      params: {
        'p_establishment_id': establishmentId,
        'p_amount': amount,
        'p_method': method,
        'p_idempotency_key': idempotencyKey,
        if (method == 'mobile_money') 'p_provider': provider,
        if (method == 'mobile_money') 'p_provider_reference': providerReference,
      },
    );
    final row = (rows as List<dynamic>).cast<Map<String, dynamic>>().first;
    return (
      status: row['payment_status'] as String,
      receiptNumber: row['receipt_number'] as String?,
    );
  }
}

final paymentsRepositoryProvider = Provider<PaymentsRepository?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : PaymentsRepository(client);
});
