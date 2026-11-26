import '../data/audit.dart';
import '../data/fs_values.dart';
import 'support_plan_form.dart';

/// 計画の状態
enum PlanStatus {
  draft('draft', '作成中'),
  agreed('agreed', '同意済み');

  const PlanStatus(this.code, this.label);
  final String code;
  final String label;

  static PlanStatus fromCode(Object? v) => v == agreed.code ? agreed : draft;
}

/// 支援の表の担当者（職員から選んだ人、または自由に書いた名前）
class PlanStaff {
  final String? staffId;
  final String name;
  const PlanStaff({this.staffId, required this.name});

  Map<String, dynamic> toMap() => {'staffId': staffId, 'name': name};

  static PlanStaff? fromMap(Object? v) {
    if (v is! Map) return null;
    final n = v['name'];
    if (n is! String || n.trim().isEmpty) return null;
    final id = v['staffId'];
    return PlanStaff(staffId: id is String ? id : null, name: n);
  }

  @override
  bool operator ==(Object other) =>
      other is PlanStaff && other.staffId == staffId && other.name == name;
  @override
  int get hashCode => Object.hash(staffId, name);
}

/// 支援の表の 1 行
class SupportPlanRow {
  /// 項目（[SupportPlanForm.categories] の code。併記できるので複数）
  final List<String> categories;

  /// 文章の項目（[SupportPlanForm.rGoal] など → 文章）
  final Map<String, String> texts;

  /// 5 領域（本人支援の行で選ぶ。[SupportPlanForm.domains] の code）
  final List<String> domains;
  final List<PlanStaff> staff;

  /// 優先順位（本人支援の行だけ。空欄は null）
  final int? priority;

  const SupportPlanRow({
    this.categories = const [],
    this.texts = const {},
    this.domains = const [],
    this.staff = const [],
    this.priority,
  });

  String text(String key) => texts[key] ?? '';

  bool hasCategory(String code) => categories.contains(code);

  /// 本人支援を含む行か（5 領域・優先順位を書く行）
  bool get usesDomains => categories
      .any((c) => SupportPlanForm.categoryOf(c)?.usesDomains ?? false);

  /// 中身がある行か（支援目標か支援内容が書いてある）
  bool get hasContent =>
      text(SupportPlanForm.rGoal).trim().isNotEmpty ||
      text(SupportPlanForm.rContent).trim().isNotEmpty;

  /// 比べるための形（文章は前後の空白を除き空を除く。項目・5 領域は様式の順。
  /// 本人支援でない行は 5 領域・優先順位を持たない）
  SupportPlanRow normalized() {
    int order(List<String> codes, String c) {
      final i = codes.indexOf(c);
      return i < 0 ? codes.length : i;
    }

    final catCodes = [for (final c in SupportPlanForm.categories) c.code];
    final domCodes = [for (final d in SupportPlanForm.domains) d.code];
    final cats = categories.toSet().toList()
      ..sort((a, b) => order(catCodes, a).compareTo(order(catCodes, b)));
    final uses = SupportPlanRow(categories: cats).usesDomains;
    final doms = domains.toSet().toList()
      ..sort((a, b) => order(domCodes, a).compareTo(order(domCodes, b)));
    return SupportPlanRow(
      categories: cats,
      texts: {
        for (final e in texts.entries)
          if (e.value.trim().isNotEmpty) e.key: e.value.trim()
      },
      domains: uses ? doms : const [],
      staff: staff,
      priority: uses ? priority : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'categories': List<String>.from(categories),
        'texts': Map<String, String>.from(texts),
        'domains': List<String>.from(domains),
        'staff': [for (final s in staff) s.toMap()],
        'priority': priority,
      };

  static SupportPlanRow fromMap(Object? v) {
    if (v is! Map) return const SupportPlanRow();
    final t = v['texts'];
    final st = v['staff'];
    final p = v['priority'];
    return SupportPlanRow(
      categories: readStringList(v['categories']),
      texts: t is Map
          ? {
              for (final e in t.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String
            }
          : const {},
      domains: readStringList(v['domains']),
      staff: st is List
          ? [
              for (final e in st)
                if (PlanStaff.fromMap(e) case final s?) s
            ]
          : const [],
      priority: p is num ? p.toInt() : null,
    );
  }

  SupportPlanRow copyWith({
    List<String>? categories,
    Map<String, String>? texts,
    List<String>? domains,
    List<PlanStaff>? staff,
    int? Function()? priority,
  }) =>
      SupportPlanRow(
        categories: categories ?? this.categories,
        texts: texts ?? this.texts,
        domains: domains ?? this.domains,
        staff: staff ?? this.staff,
        priority: priority == null ? this.priority : priority(),
      );
}

/// 個別支援計画（facilities/{facilityId}/supportPlans/{planId}）。1 計画 1 文書。
///
/// 支援の表の行は計画の中に持つ。計画は削除しない（履歴として残す）。
class SupportPlan {
  final String id;
  final String customerId;

  /// 作成したときの利用児の氏名・生年月日（顧客の情報から自動で入る）
  final String customerName;
  final DateTime? birthday;

  /// 作成年月日（更新期限の起点）
  final DateTime? createdOn;
  final String? managerStaffId;
  final String managerName;

  /// 方針の文章（[SupportPlanForm.policyFields] のキー → 文章）
  final Map<String, String> texts;
  final List<SupportPlanRow> rows;

  final DateTime? explainedOn;
  final DateTime? agreedOn;
  final PlanStatus status;

  /// アセスメントを実施した日（更新時期の知らせを消すのに使う）
  final DateTime? assessmentDoneOn;

  /// 「前回の内容を写して作る」で作ったときの元の計画
  final String? copiedFromPlanId;

  /// 同意後の軽い修正（同意済みのまま直した日時と担当者）
  final DateTime? revisedAfterAgreementAt;
  final String? revisedAfterAgreementByStaffId;
  final String? revisedAfterAgreementByStaffName;

  // 記録（読み取り専用）
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? updatedByStaffId;
  final String? updatedByStaffName;

  const SupportPlan({
    required this.id,
    required this.customerId,
    this.customerName = '',
    this.birthday,
    this.createdOn,
    this.managerStaffId,
    this.managerName = '',
    this.texts = const {},
    this.rows = const [],
    this.explainedOn,
    this.agreedOn,
    this.status = PlanStatus.draft,
    this.assessmentDoneOn,
    this.copiedFromPlanId,
    this.revisedAfterAgreementAt,
    this.revisedAfterAgreementByStaffId,
    this.revisedAfterAgreementByStaffName,
    this.createdAt,
    this.updatedAt,
    this.updatedByStaffId,
    this.updatedByStaffName,
  });

  bool get isAgreed => status == PlanStatus.agreed;

  /// 同意後に軽い修正をしたか
  bool get revisedAfterAgreement => isAgreed && revisedAfterAgreementAt != null;

  String text(String key) => texts[key] ?? '';

  // ── 保存の形 ───────────────────────────────────────────────
  static const String fRevisedAt = 'revisedAfterAgreementAt';
  static const String fRevisedById = 'revisedAfterAgreementByStaffId';
  static const String fRevisedByName = 'revisedAfterAgreementByStaffName';

  /// 業務データ（記録欄・同意後の修正の記録を除く）
  Map<String, dynamic> toFirestoreData() => {
        'customerId': customerId,
        'customerName': customerName,
        'birthday': dateOnlyToString(birthday),
        'createdOn': dateOnlyToString(createdOn),
        'managerStaffId': managerStaffId,
        'managerName': managerName,
        'texts': Map<String, String>.from(texts),
        'rows': [for (final r in rows) r.toMap()],
        'explainedOn': dateOnlyToString(explainedOn),
        'agreedOn': dateOnlyToString(agreedOn),
        'status': status.code,
        'assessmentDoneOn': dateOnlyToString(assessmentDoneOn),
        'copiedFromPlanId': copiedFromPlanId,
      };

  factory SupportPlan.fromFirestore(String id, Map<String, dynamic> d) {
    final t = d['texts'];
    final rows = d['rows'];
    return SupportPlan(
      id: id,
      customerId: readString(d['customerId']) ?? '',
      customerName: readString(d['customerName']) ?? '',
      birthday: dateOnlyFromString(d['birthday']),
      createdOn: dateOnlyFromString(d['createdOn']),
      managerStaffId: readString(d['managerStaffId']),
      managerName: readString(d['managerName']) ?? '',
      texts: t is Map
          ? {
              for (final e in t.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String
            }
          : const {},
      rows: rows is List
          ? [for (final r in rows) SupportPlanRow.fromMap(r)]
          : const [],
      explainedOn: dateOnlyFromString(d['explainedOn']),
      agreedOn: dateOnlyFromString(d['agreedOn']),
      status: PlanStatus.fromCode(d['status']),
      assessmentDoneOn: dateOnlyFromString(d['assessmentDoneOn']),
      copiedFromPlanId: readString(d['copiedFromPlanId']),
      revisedAfterAgreementAt: readTimestamp(d[fRevisedAt]),
      revisedAfterAgreementByStaffId: readString(d[fRevisedById]),
      revisedAfterAgreementByStaffName: readString(d[fRevisedByName]),
      createdAt: readTimestamp(d[AuditStamp.fCreatedAt]),
      updatedAt: readTimestamp(d[AuditStamp.fUpdatedAt]),
      updatedByStaffId: readString(d[AuditStamp.fUpdatedByStaffId]),
      updatedByStaffName: readString(d[AuditStamp.fUpdatedByStaffName]),
    );
  }

  /// 比べるための形（文章は前後の空白を除き空を除く。行は [SupportPlanRow.normalized]）
  SupportPlan normalized() => copyWith(
        customerName: customerName,
        texts: {
          for (final e in texts.entries)
            if (e.value.trim().isNotEmpty) e.key: e.value.trim()
        },
        rows: [for (final r in rows) r.normalized()],
        managerName: managerName.trim(),
      );

  /// 業務データの中身が同じか（記録欄は比べない。空の文章・空白・並びの違いは同じとみなす）
  bool sameContent(SupportPlan o) {
    final a = normalized().toFirestoreData(),
        b = o.normalized().toFirestoreData();
    return fsChangedFields(a, b).isEmpty && fsChangedFields(b, a).isEmpty;
  }

  SupportPlan copyWith({
    String? id,
    String? customerName,
    DateTime? Function()? birthday,
    DateTime? Function()? createdOn,
    String? Function()? managerStaffId,
    String? managerName,
    Map<String, String>? texts,
    List<SupportPlanRow>? rows,
    DateTime? Function()? explainedOn,
    DateTime? Function()? agreedOn,
    PlanStatus? status,
    DateTime? Function()? assessmentDoneOn,
    String? Function()? copiedFromPlanId,
  }) =>
      SupportPlan(
        id: id ?? this.id,
        customerId: customerId,
        customerName: customerName ?? this.customerName,
        birthday: birthday == null ? this.birthday : birthday(),
        createdOn: createdOn == null ? this.createdOn : createdOn(),
        managerStaffId:
            managerStaffId == null ? this.managerStaffId : managerStaffId(),
        managerName: managerName ?? this.managerName,
        texts: texts ?? this.texts,
        rows: rows ?? this.rows,
        explainedOn: explainedOn == null ? this.explainedOn : explainedOn(),
        agreedOn: agreedOn == null ? this.agreedOn : agreedOn(),
        status: status ?? this.status,
        assessmentDoneOn: assessmentDoneOn == null
            ? this.assessmentDoneOn
            : assessmentDoneOn(),
        copiedFromPlanId: copiedFromPlanId == null
            ? this.copiedFromPlanId
            : copiedFromPlanId(),
        revisedAfterAgreementAt: revisedAfterAgreementAt,
        revisedAfterAgreementByStaffId: revisedAfterAgreementByStaffId,
        revisedAfterAgreementByStaffName: revisedAfterAgreementByStaffName,
        createdAt: createdAt,
        updatedAt: updatedAt,
        updatedByStaffId: updatedByStaffId,
        updatedByStaffName: updatedByStaffName,
      );

  /// 記録欄だけを差し替えたもの（保存した直後の画面用）
  SupportPlan withRecords({
    DateTime? revisedAt,
    String? revisedById,
    String? revisedByName,
    required DateTime updatedAt,
    String? updatedById,
    required String updatedByName,
    DateTime? createdAt,
  }) =>
      SupportPlan(
        id: id,
        customerId: customerId,
        customerName: customerName,
        birthday: birthday,
        createdOn: createdOn,
        managerStaffId: managerStaffId,
        managerName: managerName,
        texts: texts,
        rows: rows,
        explainedOn: explainedOn,
        agreedOn: agreedOn,
        status: status,
        assessmentDoneOn: assessmentDoneOn,
        copiedFromPlanId: copiedFromPlanId,
        revisedAfterAgreementAt: revisedAt,
        revisedAfterAgreementByStaffId: revisedById,
        revisedAfterAgreementByStaffName: revisedByName,
        createdAt: createdAt,
        updatedAt: updatedAt,
        updatedByStaffId: updatedById,
        updatedByStaffName: updatedByName,
      );

  /// 前回の内容を写した新しい計画（日付・説明・同意・アセスメントは空にする）
  SupportPlan copyAsNew({required String newId, required DateTime today}) =>
      SupportPlan(
        id: newId,
        customerId: customerId,
        customerName: customerName,
        birthday: birthday,
        createdOn: today,
        managerStaffId: managerStaffId,
        managerName: managerName,
        texts: Map<String, String>.from(texts),
        rows: List<SupportPlanRow>.from(rows),
        copiedFromPlanId: id,
      );
}

/// 計画の足りない点・確かめる点
class PlanCheck {
  /// 同意済みにできない理由（足りない点）。空なら同意済みにできる
  final List<String> blockers;

  /// 本人支援の行全体で選ばれていない 5 領域（同意済みにする前に確かめる。止めない）
  final List<String> missingDomains;

  const PlanCheck(this.blockers, this.missingDomains);

  bool get canAgree => blockers.isEmpty;

  static String _ymd(DateTime d) => '${d.year}/${d.month}/${d.day}';

  /// [p] を確かめる
  static PlanCheck of(SupportPlan p) {
    final b = <String>[];
    if (p.createdOn == null) b.add('${SupportPlanForm.createdOnLabel}が入っていません');
    if (p.managerName.trim().isEmpty) {
      b.add('${SupportPlanForm.managerLabel}が選ばれていません');
    }
    for (final c in SupportPlanForm.categories.where((c) => c.required)) {
      final has = p.rows.any((r) => r.hasCategory(c.code) && r.hasContent);
      if (!has) b.add('「${c.label}」の行がありません（支援目標か支援内容を書いた行が 1 行以上要ります）');
    }
    // 作成年月日 ≦ 説明した日 ≦ 同意を得た日（同じ日は可）
    final created = p.createdOn, explained = p.explainedOn, agreed = p.agreedOn;
    if (created != null && explained != null && explained.isBefore(created)) {
      b.add('${SupportPlanForm.explainedOnLabel}（${_ymd(explained)}）が'
          '${SupportPlanForm.createdOnLabel}（${_ymd(created)}）より前です');
    }
    if (explained != null && agreed != null && agreed.isBefore(explained)) {
      b.add('${SupportPlanForm.agreedOnLabel}（${_ymd(agreed)}）が'
          '${SupportPlanForm.explainedOnLabel}（${_ymd(explained)}）より前です');
    }
    // 同意を得るには、先に説明している（説明した日が要る）
    if (agreed != null && explained == null) {
      b.add('${SupportPlanForm.explainedOnLabel}が入っていません');
    }
    final chosen = <String>{
      for (final r in p.rows)
        if (r.usesDomains) ...r.domains
    };
    final missing = [
      for (final d in SupportPlanForm.domains)
        if (!chosen.contains(d.code)) d.label
    ];
    return PlanCheck(b, missing);
  }
}
