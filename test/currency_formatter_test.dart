import 'package:flutter_test/flutter_test.dart';
import 'package:terenza/core/utils/currency_formatter.dart';

void main() {
  group('CurrencyFormatter', () {
    test('groups thousands and appends FCFA', () {
      expect(CurrencyFormatter.formatCfa(70000), '70 000 FCFA');
    });

    test('formats negative values without losing the sign', () {
      expect(CurrencyFormatter.formatCfa(-1250000), '-1 250 000 FCFA');
    });
  });
}
