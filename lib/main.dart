import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/network/offline_store.dart';
import 'core/network/offline_sync_manager.dart';
import 'core/network/supabase_client_provider.dart';
import 'core/security/supabase_secure_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  SupabaseClient? client;
  OfflineStore? offlineStore;

  try {
    offlineStore = await OfflineStore.open();
  } catch (_) {
    offlineStore = null;
  }

  if (config.hasSupabaseConfiguration) {
    const secureStorage = FlutterSecureStorage();
    try {
      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.supabasePublishableKey,
        authOptions: FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          localStorage: const SupabaseSecureLocalStorage(secureStorage),
          pkceAsyncStorage: const SupabaseSecurePkceStorage(secureStorage),
        ),
      );
      client = Supabase.instance.client;
    } catch (_) {
      client = null;
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        supabaseClientProvider.overrideWithValue(client),
        offlineStoreProvider.overrideWithValue(offlineStore),
      ],
      child: const TerenzaApp(),
    ),
  );
}
