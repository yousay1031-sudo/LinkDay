import 'support_plan.dart';

/// 個別支援計画の更新期限の決まり（日数・月数はここだけに置く。設定画面には出さない）。
class SupportPlanPolicy {
  SupportPlanPolicy._();

  /// 作成年月日から更新期限までの月数
  static const int validMonths = 6;

  /// 期限の何日前から「アセスメントの時期です」を出すか
  static const int assessmentLeadDays = 45;

  /// 期限の何日前から「計画の更新期限が近づいています」を出すか
  static const int nearDays = 14;

  /// [d] の [months] か月後の同じ日。その日が無い月はその月の末日
  /// （例: 8月31日の6か月後 → 2月28日、うるう年は29日）。
  static DateTime addMonthsClamped(DateTime d, int months) {
    final total = d.year * 12 + (d.month - 1) + months;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final lastDay = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, d.day > lastDay ? lastDay : d.day);
  }

  /// 作成年月日 → 更新期限
  static DateTime dueOf(DateTime createdOn) => addMonthsClamped(
      DateTime(createdOn.year, createdOn.month, createdOn.day), validMonths);

  /// 期限の起点にする計画。
  ///
  /// 同意済みの計画のうち作成年月日がいちばん新しいもの。同意済みが無く作成中だけが
  /// あるときは、作成中のうち作成年月日がいちばん新しいものを仮の起点にする
  /// （承認済みの判断点2 (ア)）。作成年月日が無い計画は起点にしない。
  static SupportPlan? basePlan(Iterable<SupportPlan> plansOfChild) {
    SupportPlan? newest(Iterable<SupportPlan> ps) {
      SupportPlan? best;
      for (final p in ps) {
        final c = p.createdOn;
        if (c == null) continue;
        final bc = best?.createdOn;
        if (best == null ||
            bc == null ||
            c.isAfter(bc) ||
            (c == bc && _createdAtAfter(p, best))) {
          best = p;
        }
      }
      return best;
    }

    return newest(plansOfChild.where((p) => p.isAgreed)) ??
        newest(plansOfChild.where((p) => !p.isAgreed));
  }

  static bool _createdAtAfter(SupportPlan a, SupportPlan b) {
    final x = a.createdAt, y = b.createdAt;
    if (x == null || y == null) return false;
    return x.isAfter(y);
  }
}
