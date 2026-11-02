import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/core/network/live_refresh.dart';

void main() {
  testWidgets('rafraîchit périodiquement puis s’arrête une fois démonté', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: LiveRefresh(
          channel: 'test',
          sources: const [],
          interval: const Duration(seconds: 1),
          onRefresh: () => refreshes++,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 3100));
    expect(refreshes, 3);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(refreshes, 3, reason: 'aucune fuite de minuterie après démontage');
  });

  testWidgets('rafraîchit au retour au premier plan, pas en arrière-plan', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: LiveRefresh(
          channel: 'test',
          sources: const [],
          interval: const Duration(seconds: 1),
          onRefresh: () => refreshes++,
          child: const SizedBox(),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 2100));
    expect(refreshes, 0, reason: 'aucune requête application masquée');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(refreshes, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
