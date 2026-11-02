import 'package:flutter_test/flutter_test.dart';
import 'package:terenza/core/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('defaults to development', () {
      expect(
        AppConfig.fromEnvironment().environment,
        AppEnvironment.development,
      );
    });

    test('rejects unknown environments', () {
      expect(() => AppConfig.fromName('staging'), throwsArgumentError);
    });
  });
}
