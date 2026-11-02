import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppEnvironment { development, test, production }

class AppConfig {
  const AppConfig({
    required this.environment,
    this.supabaseUrl = 'https://aneccnzdxwyqveexqmap.supabase.co',
    this.supabasePublishableKey =
        'sb_publishable_AY0SDJ4_hR19E77P2D02mA_YzQemfTW',
  });

  final AppEnvironment environment;
  final String supabaseUrl;
  final String supabasePublishableKey;

  bool get isProduction => environment == AppEnvironment.production;

  bool get hasSupabaseConfiguration =>
      supabaseUrl.startsWith('https://') && supabasePublishableKey.isNotEmpty;

  factory AppConfig.fromEnvironment() {
    const environmentName = String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'development',
    );

    const supabaseUrl = String.fromEnvironment(
      'SUPABASE_URL',
      defaultValue: 'https://aneccnzdxwyqveexqmap.supabase.co',
    );

    const supabasePublishableKey = String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
      defaultValue: 'sb_publishable_AY0SDJ4_hR19E77P2D02mA_YzQemfTW',
    );

    return AppConfig.fromName(
      environmentName,
      supabaseUrl: supabaseUrl,
      supabasePublishableKey: supabasePublishableKey,
    );
  }

  factory AppConfig.fromName(
    String name, {
    String supabaseUrl = 'https://aneccnzdxwyqveexqmap.supabase.co',
    String supabasePublishableKey =
        'sb_publishable_AY0SDJ4_hR19E77P2D02mA_YzQemfTW',
  }) {
    return AppConfig(
      environment: switch (name) {
        'development' => AppEnvironment.development,
        'test' => AppEnvironment.test,
        'production' => AppEnvironment.production,
        _ => throw ArgumentError.value(name, 'name', 'Unknown app environment'),
      },
      supabaseUrl: supabaseUrl,
      supabasePublishableKey: supabasePublishableKey,
    );
  }
}

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment(),
);
