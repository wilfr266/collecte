import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/app/app.dart';
import 'package:terenza/core/config/app_config.dart';

void main() {
  testWidgets('app does not fake an authenticated session', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              environment: AppEnvironment.test,
              supabaseUrl: '',
              supabasePublishableKey: '',
            ),
          ),
        ],
        child: const TerenzaApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'L’application n’est pas encore configurée. Contactez votre administrateur.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a configured but uninitialised client never opens a space', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TerenzaApp()));
    await tester.pumpAndSettle();

    expect(find.text('Connexion indisponible'), findsOneWidget);
  });
}
