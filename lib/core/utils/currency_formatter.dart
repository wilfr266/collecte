abstract final class CurrencyFormatter {
  static final _groupingPattern = RegExp(r'\B(?=(\d{3})+(?!\d))');

  static String formatCfa(int amount) {
    final groupedAmount = amount.abs().toString().replaceAllMapped(
      _groupingPattern,
      (match) => ' ',
    );
    final sign = amount < 0 ? '-' : '';
    return '$sign$groupedAmount FCFA';
  }
}
