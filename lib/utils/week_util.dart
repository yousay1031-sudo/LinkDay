/// 週計算ユーティリティ
class WeekUtil {
  WeekUtil._();

  /// 指定日の月曜日 0:00 を返す
  static DateTime weekStartFromDate(DateTime d) {
    final diff = d.weekday - 1; // weekday: 1=月, 7=日
    return DateTime(d.year, d.month, d.day - diff);
  }

  /// ISO 8601 週番号で "YYYY-Www" 形式のキーを返す（例: "2026-W25"）
  static String weekKeyFromDate(DateTime d) {
    final monday = weekStartFromDate(d);
    // ISO week number: Jan 4 は必ず第1週に含まれる
    final jan4 = DateTime(monday.year, 1, 4);
    final firstMonday = weekStartFromDate(jan4);
    final weekNum =
        ((monday.difference(firstMonday).inDays) / 7).floor() + 1;

    // 年末年始の週番号ズレを補正
    if (weekNum < 1) {
      // 前年の最終週
      final prevJan4 = DateTime(monday.year - 1, 1, 4);
      final prevFirstMonday = weekStartFromDate(prevJan4);
      final prevWeekNum =
          ((monday.difference(prevFirstMonday).inDays) / 7).floor() + 1;
      return '${monday.year - 1}-W${prevWeekNum.toString().padLeft(2, '0')}';
    }
    if (weekNum > 52) {
      // 翌年の第1週かどうかチェック
      final nextJan4 = DateTime(monday.year + 1, 1, 4);
      final nextFirstMonday = weekStartFromDate(nextJan4);
      if (!monday.isBefore(nextFirstMonday)) {
        return '${monday.year + 1}-W01';
      }
    }
    return '${monday.year}-W${weekNum.toString().padLeft(2, '0')}';
  }

  /// weekKey から月曜日の DateTime を復元する
  static DateTime weekStartFromKey(String weekKey) {
    // "2026-W25" → year=2026, week=25
    final parts = weekKey.split('-W');
    final year = int.parse(parts[0]);
    final week = int.parse(parts[1]);
    // ISO 第1週: 1月4日が含まれる週の月曜日
    final jan4 = DateTime(year, 1, 4);
    final firstMonday = weekStartFromDate(jan4);
    return firstMonday.add(Duration(days: (week - 1) * 7));
  }

  /// 翌週の月曜日を返す
  static DateTime nextWeekStart(DateTime weekStart) =>
      weekStart.add(const Duration(days: 7));

  /// 前週の月曜日を返す
  static DateTime previousWeekStart(DateTime weekStart) =>
      weekStart.subtract(const Duration(days: 7));

  /// 曜日番号（1=月〜7=日）→ 日本語短縮
  static String dayOfWeekJp(int d) {
    const labels = {1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土', 7: '日'};
    return labels[d] ?? '?';
  }

  /// 週の表示ラベルを返す（例: "2026年6月15日（月）〜 6月21日（日）"）
  static String weekRangeLabel(DateTime monday) {
    final sunday = monday.add(const Duration(days: 6));
    final startLabel =
        '${monday.year}年${monday.month}月${monday.day}日（月）';
    final endLabel = sunday.month == monday.month
        ? '${sunday.day}日（日）'
        : '${sunday.month}月${sunday.day}日（日）';
    return '$startLabel〜 $endLabel';
  }

  /// 月内の第N週ラベル（例: "第3週 / 6月"）
  static String weekInMonthLabel(DateTime monday) {
    final firstDayOfMonth = DateTime(monday.year, monday.month, 1);
    final firstMonday = weekStartFromDate(
      firstDayOfMonth.add(
        Duration(days: (8 - firstDayOfMonth.weekday) % 7),
      ),
    );
    final weekNum =
        ((monday.difference(firstMonday).inDays) / 7).floor() + 1;
    return '第$weekNum週 / ${monday.month}月';
  }
}
