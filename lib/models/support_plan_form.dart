/// 個別支援計画の様式（見出しと並び）を 1 か所にまとめたもの。
///
/// こども家庭庁の参考様式（令和6年度報酬改定。別紙1-1「個別支援計画参考様式」と
/// 記載のポイント・参考記載例）の見出しの文言をそのまま使う。
/// 地域や事業所で項目が少し違う場合は、ここの一覧を足したり外したりする
/// （入力画面・必須の確かめ・印刷はこの一覧から作る）。
///
/// 保存の形: 方針の文章は計画の `texts`（キー → 文章）、支援の表の 1 行の文章は
/// 行の `texts` に置く。一覧から外した項目の値は消さずに残る（読み書きで捨てない）。
library;

/// 方針の欄（自由入力の文章）
class PlanTextField {
  final String key;

  /// 様式の見出し（印刷にもこのまま出す）
  final String label;

  /// 入力欄の説明（様式の注記・記載のポイントから）
  final String hint;

  const PlanTextField(this.key, this.label, this.hint);
}

/// 支援の表の項目（本人支援・家族支援・移行支援・地域支援・地域連携）
class PlanCategory {
  final String code;
  final String label;

  /// 必ず 1 行以上要るか（記載のポイント：本人支援・家族支援・移行支援は必ず記載）
  final bool required;

  /// 5 領域との関連・優先順位を書く項目か（本人支援だけ）
  final bool usesDomains;

  const PlanCategory(this.code, this.label,
      {this.required = false, this.usesDomains = false});
}

/// 5 領域
class PlanDomain {
  final String code;
  final String label;
  const PlanDomain(this.code, this.label);
}

/// 支援の表の列
class PlanColumn {
  final String key;
  final String label;
  const PlanColumn(this.key, this.label);
}

class SupportPlanForm {
  SupportPlanForm._();

  static const String title = '個別支援計画書';

  // ── 上の部分 ──────────────────────────────────────────────
  static const String childNameLabel = '利用児氏名';
  static const String createdOnLabel = '作成年月日';
  static const String managerLabel = '児童発達支援管理責任者氏名';

  // ── 方針の部分（上から順に。様式では長期目標・短期目標の右に
  //    「支援の標準的な提供時間等」がある） ─────────────────────
  static const String kIntention = 'intention';
  static const String kPolicy = 'policy';
  static const String kLongTerm = 'longTerm';
  static const String kShortTerm = 'shortTerm';
  static const String kStandardTime = 'standardTime';

  static const List<PlanTextField> policyFields = [
    PlanTextField(kIntention, '利用児及び家族の生活に対する意向',
        'こども本人や家族の意向を聴いた上で、家族より得た情報やこどもの発達段階や特性等を踏まえて、整理して記載する。'),
    PlanTextField(kPolicy, '総合的な支援の方針',
        '1年間を目途に、事業所としてのこども等の状況の見立てと、どのように支援をしていくのかという方針を記載する。'),
    PlanTextField(kLongTerm, '長期目標（内容・期間等）',
        '総合的な支援の方針で掲げた内容を踏まえ、概ね１年程度で目指す目標を設定して記載する。'),
    PlanTextField(
        kShortTerm, '短期目標（内容・期間等）', '長期目標で掲げた内容を踏まえ、概ね６か月程度で目指す目標を設定して記載する。'),
    PlanTextField(kStandardTime, '支援の標準的な提供時間等（曜日・頻度、時間）', '利用曜日・提供時間等を記載。'),
  ];

  // ── 支援の表 ──────────────────────────────────────────────
  static const String tableTitle = '○支援目標及び具体的な支援内容等';

  static const String cSelf = 'self';
  static const String cFamily = 'family';
  static const String cTransition = 'transition';
  static const String cCommunity = 'community';

  static const List<PlanCategory> categories = [
    PlanCategory(cSelf, '本人支援', required: true, usesDomains: true),
    PlanCategory(cFamily, '家族支援', required: true),
    PlanCategory(cTransition, '移行支援', required: true),
    PlanCategory(cCommunity, '地域支援・地域連携'),
  ];

  static const List<PlanDomain> domains = [
    PlanDomain('health', '健康・生活'),
    PlanDomain('motor', '運動・感覚'),
    PlanDomain('cognition', '認知・行動'),
    PlanDomain('language', '言語・コミュニケーション'),
    PlanDomain('social', '人間関係・社会性'),
  ];

  /// 行の文章の項目のキー
  static const String rGoal = 'goal';
  static const String rContent = 'content';
  static const String rPeriod = 'period';
  static const String rProvider = 'provider';
  static const String rNotes = 'notes';

  /// 支援の表の列（印刷の並びと見出し）
  static const List<PlanColumn> columns = [
    PlanColumn('category', '項目'),
    PlanColumn(rGoal, '支援目標\n（具体的な到達目標）'),
    PlanColumn(rContent, '支援内容\n（内容・支援の提供上のポイント・5領域（※）との関連性等）'),
    PlanColumn(rPeriod, '達成時期'),
    PlanColumn('staff', '担当者\n提供機関'),
    PlanColumn(rNotes, '留意事項\n（本人の役割を含む）'),
    PlanColumn('priority', '優先順位'),
  ];

  /// 入力欄の見出し（1 行で出す）
  static const String goalLabel = '支援目標（具体的な到達目標）';
  static const String contentLabel = '支援内容（内容・支援の提供上のポイント）';
  static const String domainsLabel = '5領域との関連';
  static const String periodLabel = '達成時期';
  static const String staffLabel = '担当者';
  static const String providerLabel = '提供機関';
  static const String notesLabel = '留意事項（本人の役割を含む）';
  static const String priorityLabel = '優先順位';

  static const String domainNote =
      '※５領域の視点 ｢健康・生活｣、｢運動・感覚｣、｢認知・行動｣、｢言語・コミュニケーション｣、｢人間関係・社会性｣';

  /// 達成時期の選択肢（記載のポイント：最長６か月後まで。１〜３か月も積極的に）
  static const List<String> periodChoices = ['1か月後', '2か月後', '3か月後', '6か月後'];

  /// 優先順位の選択肢（本人支援の行だけ。空欄・同じ番号も可）
  static const List<int> priorityChoices = [1, 2, 3, 4, 5];

  // ── 下の部分（説明と同意） ──────────────────────────────────
  static const String explainedText = '提供する支援内容について、本計画書に基づき説明しました。';
  static const String agreedText = '本計画書に基づき支援の説明を受け、内容に同意しました。';
  static const String guardianSignLabel = '（保護者署名）';
  static const String explainedOnLabel = '説明した日';
  static const String agreedOnLabel = '同意を得た日';

  static PlanCategory? categoryOf(String code) {
    for (final c in categories) {
      if (c.code == code) return c;
    }
    return null;
  }

  static String categoryLabel(String code) => categoryOf(code)?.label ?? code;

  static String domainLabel(String code) {
    for (final d in domains) {
      if (d.code == code) return d.label;
    }
    return code;
  }
}
