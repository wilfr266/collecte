import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseSecureLocalStorage extends LocalStorage {
  const SupabaseSecureLocalStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _sessionKey = 'terenza.supabase.session';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async =>
      await _storage.containsKey(key: _sessionKey);

  @override
  Future<String?> accessToken() => _storage.read(key: _sessionKey);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _sessionKey, value: persistSessionString);
}

class SupabaseSecurePkceStorage extends GotrueAsyncStorage {
  const SupabaseSecurePkceStorage(this._storage);

  final FlutterSecureStorage _storage;

  String _key(String key) => 'terenza.supabase.pkce.$key';

  @override
  Future<String?> getItem({required String key}) =>
      _storage.read(key: _key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _storage.write(key: _key(key), value: value);

  @override
  Future<void> removeItem({required String key}) =>
      _storage.delete(key: _key(key));
}
