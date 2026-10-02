import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/notification_log.dart';
import 'attendance_service.dart';
import 'customer_service.dart';
import 'monthly_usage_service.dart';
import 'settings_service.dart';

/// 空き枠通知の候補 1 件
///
/// 【「候補」の定義（Day 11 最終仕様）】
/// 欠席が出た日付 [date] について、以下すべてを満たす児童。
///   a. その日の出席レコードが存在しない
///      （scheduled / present / departed / absent のいずれも無い）
///      → 「予定」だけでも入っている児童は既にその日来る予定なので対象外。
///   b. 欠席者本人ではない
///   c. MonthlyUsageService の remainingProjected > 0（支給量に余裕がある）
///   d. 在籍中（isActive）
/// そのうち lineUserId が登録済みのものが送信対象（[canNotify] == true）。
/// 未登録のものは「LINE未連携」として分離表示し、電話案内の参考にする。
@immutable
class VacancyCandidate {
  final String customerId;
  final String childName;

  /// 登録済み LINE userId（未連携なら null）
  final String? lineUserId;

  /// 見込み残日数（MonthlyUsage.remainingProjected）
  final int remainingProjected;

  /// 定期利用曜日（1=月 … 6=土）
  final List<int> regularDays;

  /// この日付に既に通知を送った記録（なければ null）
  final NotificationLog? existingLog;

  const VacancyCandidate({
    required this.customerId,
    required this.childName,
    required this.lineUserId,
    required this.remainingProjected,
    required this.regularDays,
    this.existingLog,
  });

  /// LINE 連携済みか
  bool get isLinked => lineUserId != null && lineUserId!.isNotEmpty;

  /// 既に通知済み（クライアント側の二重送信ブロック対象）
  bool get alreadyNotified {
    final log = existingLog;
    return log != null && log.blocksResend;
  }

  /// 送信可能（連携済み かつ 未通知）
  bool get canNotify => isLinked && !alreadyNotified;

  /// 定期曜日の表示ラベル（例: 月・水・金）
  String get regularDaysLabel {
    if (regularDays.isEmpty) return '定期なし';
    const names = ['月', '火', '水', '木', '金', '土', '日'];
    final sorted = [...regularDays]..sort();
    return sorted
        .where((d) => d >= 1 && d <= 7)
        .map((d) => names[d - 1])
        .join('・');
  }

  @override
  String toString() => 'VacancyCandidate($childName, '
      'remain=$remainingProjected, linked=$isLinked, '
      'notified=$alreadyNotified)';
}

/// 候補抽出の結果
@immutable
class VacancyCandidateResult {
  /// 対象日
  final DateTime date;

  /// その日の欠席者（抽出の除外対象）
  final List<String> absentCustomerIds;

  /// LINE 連携済みの候補（送信対象。既に通知済みのものも含む）
  final List<VacancyCandidate> linked;

  /// LINE 未連携の候補（送信対象外。電話案内の参考）
  final List<VacancyCandidate> unlinked;

  const VacancyCandidateResult({
    required this.date,
    required this.absentCustomerIds,
    required this.linked,
    required this.unlinked,
  });

  /// 送信可能（連携済みかつ未通知）な候補
  List<VacancyCandidate> get notifiable =>
      linked.where((c) => c.canNotify).toList();

  /// 既に通知済みの候補
  List<VacancyCandidate> get alreadyNotified =>
      linked.where((c) => c.alreadyNotified).toList();

  /// 候補が 1 件もない
  bool get isEmpty => linked.isEmpty && unlinked.isEmpty;

  int get totalCount => linked.length + unlinked.length;

  @override
  String toString() => 'VacancyCandidateResult(${_dateKey(date)}, '
      'linked=${linked.length}, notifiable=${notifiable.length}, '
      'unlinked=${unlinked.length})';
}

/// 送信結果 1 件
@immutable
class VacancySendResultItem {
  final String customerId;
  final String childName;
  final NotificationStatus status;
  final int? httpStatus;
  final String? error;

  const VacancySendResultItem({
    required this.customerId,
    required this.childName,
    required this.status,
    this.httpStatus,
    this.error,
  });
}

/// 送信結果まとめ
@immutable
class VacancySendResult {
  final List<VacancySendResultItem> items;

  /// 送信そのものが失敗した場合のエラー（認証切れ・通信断など）
  final String? fatalError;

  const VacancySendResult({required this.items, this.fatalError});

  int get sentCount =>
      items.where((e) => e.status == NotificationStatus.sent).length;
  int get failedCount =>
      items.where((e) => e.status == NotificationStatus.failed).length;
  int get duplicateCount =>
      items.where((e) => e.status == NotificationStatus.duplicate).length;
  int get invalidCount => items
      .where((e) => e.status == NotificationStatus.invalidLineUserId)
      .length;

  bool get hasFatalError => fatalError != null;

  String get summaryLabel {
    if (hasFatalError) return '送信できませんでした';
    final parts = <String>['成功 $sentCount件'];
    if (failedCount > 0) parts.add('失敗 $failedCount件');
    if (duplicateCount > 0) parts.add('送信済み $duplicateCount件');
    if (invalidCount > 0) parts.add('ID不正 $invalidCount件');
    return parts.join(' / ');
  }
}

String _dateKey(DateTime d) => NotificationLog.makeDateKey(d);

/// 空き枠 LINE 通知サービス（Day 11）
///
/// 【責務】
/// 1. 欠席発生日の「空き枠を埋められる候補」抽出（[findCandidates]）
/// 2. Callable Function `sendVacancyNotice` の呼び出し（[sendNotices]）
/// 3. 送信記録の端末内保存（Hive box 'notification_logs'）
/// 4. LINE 連携コードの発行・連携状況の同期（Firestore）
///
/// 【既存フローへの非干渉】
/// AttendanceService.markAbsent 本体には一切手を入れない。
/// 欠席保存後に本サービスを「フック」として呼ぶだけ。
/// 支給量の集計は MonthlyUsageService の公開 API 経由のみ
/// （Hive box を直接触らない）。
class VacancyNotificationService {
  VacancyNotificationService._();
  static final VacancyNotificationService instance =
      VacancyNotificationService._();

  static const String boxName = 'notification_logs';

  /// Functions のリージョン（functions/src/config.ts の REGION と一致必須）
  static const String functionsRegion = 'asia-northeast1';

  /// Callable Function 名
  static const String callableName = 'sendVacancyNotice';

  /// Firestore コレクション名（functions/src/config.ts と一致必須）
  static const String colLineLinkage = 'line_linkage';
  static const String colLinkingCodes = 'linking_codes';

  /// 連携コードの有効期限（7日）
  static const Duration linkingCodeTtl = Duration(days: 7);

  /// 一度に送れる宛先数の上限（Functions 側 MAX_RECIPIENTS と一致）
  static const int maxRecipients = 50;

  late Box<NotificationLog> _box;

  /// テスト・オフライン時に Firestore / Functions を使わないためのフラグ
  bool _remoteEnabled = true;

  /// LINE userId の形式（U + 32桁 16進英数字）
  static final RegExp lineUserIdPattern = RegExp(r'^U[0-9a-fA-F]{32}$');

  static bool isValidLineUserId(String? id) {
    if (id == null) return false;
    return lineUserIdPattern.hasMatch(id.trim());
  }

  // ── 初期化 ──────────────────────────────────────────────────

  Future<void> init({bool remoteEnabled = true}) async {
    _box = await Hive.openBox<NotificationLog>(boxName);
    _remoteEnabled = remoteEnabled;
    debugPrint('[VacancyNotification] initialized. logs=${_box.length}, '
        'remote=$_remoteEnabled');
  }

  /// テストでリモート呼び出しを止める
  @visibleForTesting
  void setRemoteEnabled(bool enabled) {
    _remoteEnabled = enabled;
  }

  // ── 候補抽出 ────────────────────────────────────────────────

  /// 空き枠通知の候補を抽出する
  ///
  /// [date] 欠席が発生した日（通常は当日）
  /// [absentCustomerIds] 今回欠席になった児童（明示指定。省略時は
  ///   その日の absent レコードから自動取得）
  /// [today] テスト用の基準日（省略時 DateTime.now()）
  Future<VacancyCandidateResult> findCandidates({
    required DateTime date,
    List<String>? absentCustomerIds,
    DateTime? today,
  }) async {
    final base = today ?? DateTime.now();
    final dateKey = _dateKey(date);
    final attendance = AttendanceService.instance;

    // 欠席者の特定
    final absentIds = <String>{
      ...?absentCustomerIds,
      ...attendance
          .getAbsentRecords(date)
          .map((r) => r.customerId),
    };

    // その日に出席レコードを持つ児童（status 問わず）
    // 「予定」だけの児童もその日来る予定なので候補から外す。
    final recordedIds = attendance
        .getRecordsByDate(date)
        .map((r) => r.customerId)
        .toSet();

    final customers = CustomerService.instance.getAllCustomers();
    final linked = <VacancyCandidate>[];
    final unlinked = <VacancyCandidate>[];

    for (final c in customers) {
      // d. 在籍中のみ（getAllCustomers は既定で isActive のみだが明示）
      if (!c.isActive) continue;

      // b. 欠席者本人は除外
      if (absentIds.contains(c.id)) continue;

      // a. その日に出席レコードがある児童は除外（予定含む）
      if (recordedIds.contains(c.id)) continue;

      // c. 支給量に余裕があるか（Day 9 の動的集計を使用）
      final usage = await MonthlyUsageService.instance.getUsage(
        c.id,
        date,
        today: base,
        // 候補抽出でキャッシュを書き換えない（副作用を持たせない）
        reconcileCache: false,
      );
      if (usage.remainingProjected <= 0) continue;

      final log = _box.get(NotificationLog.makeBoxKey(dateKey, c.id));
      final lineId = (c.lineUserId ?? '').trim();

      final candidate = VacancyCandidate(
        customerId: c.id,
        childName: c.name,
        lineUserId: lineId.isEmpty ? null : lineId,
        remainingProjected: usage.remainingProjected,
        regularDays: List<int>.unmodifiable(c.regularDays),
        existingLog: log,
      );

      if (candidate.isLinked) {
        linked.add(candidate);
      } else {
        unlinked.add(candidate);
      }
    }

    // 見込み残が多い＝枠を埋めやすい順に並べる
    linked.sort((a, b) {
      final r = b.remainingProjected.compareTo(a.remainingProjected);
      return r != 0 ? r : a.childName.compareTo(b.childName);
    });
    unlinked.sort((a, b) {
      final r = b.remainingProjected.compareTo(a.remainingProjected);
      return r != 0 ? r : a.childName.compareTo(b.childName);
    });

    final result = VacancyCandidateResult(
      date: date,
      absentCustomerIds: absentIds.toList(),
      linked: linked,
      unlinked: unlinked,
    );
    debugPrint('[VacancyNotification] findCandidates $dateKey: '
        'absent=${absentIds.length}, recorded=${recordedIds.length}, '
        'linked=${linked.length}(notifiable=${result.notifiable.length}), '
        'unlinked=${unlinked.length}');
    return result;
  }

  // ── 通知文面 ────────────────────────────────────────────────

  /// 通知文面を生成する（AppSettings の事業所名・期限時刻を差し込む）
  String buildMessage(DateTime date) {
    final s = SettingsService.instance.getSettings();
    return s.buildVacancyMessage(dateLabel: '${date.month}/${date.day}');
  }

  // ── 送信 ────────────────────────────────────────────────────

  /// 候補へ LINE 通知を送信する
  ///
  /// 【二重送信の二重ガード】
  /// 1. クライアント: Hive の送信済み記録を持つ宛先はリクエストに含めない
  /// 2. サーバー: notification_logs の create で ALREADY_EXISTS を検出
  ///
  /// [candidates] 送信対象（職員がチェックを外したものは渡さない）
  Future<VacancySendResult> sendNotices({
    required DateTime date,
    required List<VacancyCandidate> candidates,
    String? messageOverride,
  }) async {
    final dateKey = _dateKey(date);
    final message = messageOverride ?? buildMessage(date);

    // ── クライアント側ガード
    final targets = <VacancyCandidate>[];
    final blocked = <VacancySendResultItem>[];

    for (final c in candidates) {
      if (!c.isLinked) {
        blocked.add(VacancySendResultItem(
          customerId: c.customerId,
          childName: c.childName,
          status: NotificationStatus.invalidLineUserId,
          error: 'LINE未連携のため送信しませんでした。',
        ));
        continue;
      }
      if (!isValidLineUserId(c.lineUserId)) {
        blocked.add(VacancySendResultItem(
          customerId: c.customerId,
          childName: c.childName,
          status: NotificationStatus.invalidLineUserId,
          error: 'LINE User ID の形式が不正です（U + 32桁英数字）。',
        ));
        continue;
      }
      final existing = _box.get(NotificationLog.makeBoxKey(dateKey, c.customerId));
      if (existing != null && existing.blocksResend) {
        debugPrint('[VacancyNotification] client-side duplicate blocked: '
            '${c.childName} $dateKey');
        blocked.add(VacancySendResultItem(
          customerId: c.customerId,
          childName: c.childName,
          status: NotificationStatus.duplicate,
          error: 'この日付・児童には既に通知済みです。',
        ));
        continue;
      }
      targets.add(c);
    }

    if (targets.isEmpty) {
      return VacancySendResult(items: blocked);
    }
    if (targets.length > maxRecipients) {
      return VacancySendResult(
        items: blocked,
        fatalError: '一度に送信できるのは $maxRecipients 件までです。'
            '（対象 ${targets.length} 件）',
      );
    }

    if (!_remoteEnabled) {
      return VacancySendResult(
        items: blocked,
        fatalError: 'オフラインのため送信できません。',
      );
    }

    // ── Callable Function 呼び出し
    try {
      final callable = FirebaseFunctions.instanceFor(region: functionsRegion)
          .httpsCallable(
        callableName,
        options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
      );

      final res = await callable.call<dynamic>({
        'date': dateKey,
        'message': message,
        'recipients': targets
            .map((c) => {
                  'customerId': c.customerId,
                  'lineUserId': c.lineUserId,
                  'childName': c.childName,
                })
            .toList(),
      });

      final items = <VacancySendResultItem>[...blocked];
      final data = res.data;
      final rawResults = (data is Map) ? data['results'] : null;

      if (rawResults is List) {
        for (final r in rawResults) {
          if (r is! Map) continue;
          final customerId = (r['customerId'] ?? '').toString();
          final childName = (r['childName'] ?? '').toString();
          final status = NotificationLog.statusFromString(
              r['status']?.toString());
          final httpStatus = r['httpStatus'] is int
              ? r['httpStatus'] as int
              : int.tryParse('${r['httpStatus']}');
          final error = r['error']?.toString();

          items.add(VacancySendResultItem(
            customerId: customerId,
            childName: childName,
            status: status,
            httpStatus: httpStatus,
            error: (error == null || error == 'null') ? null : error,
          ));

          // 端末内にも記録（履歴表示・次回の二重送信ブロック）
          final target = targets.firstWhere(
            (t) => t.customerId == customerId,
            orElse: () => VacancyCandidate(
              customerId: customerId,
              childName: childName,
              lineUserId: null,
              remainingProjected: 0,
              regularDays: const [],
            ),
          );
          await _saveLog(NotificationLog(
            customerId: customerId,
            childName: childName.isEmpty ? target.childName : childName,
            dateKey: dateKey,
            status: status,
            httpStatus: httpStatus,
            error: (error == null || error == 'null') ? null : error,
            lineUserIdSuffix: _suffix(target.lineUserId),
            message: message,
          ));
        }
      }

      final out = VacancySendResult(items: items);
      debugPrint('[VacancyNotification] sendNotices $dateKey: ${out.summaryLabel}');
      return out;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[VacancyNotification] callable error: ${e.code} / ${e.message}');
      return VacancySendResult(
        items: blocked,
        fatalError: _localizeFunctionsError(e),
      );
    } catch (e) {
      debugPrint('[VacancyNotification] unexpected error: $e');
      return VacancySendResult(
        items: blocked,
        fatalError: '通知の送信中にエラーが発生しました。通信状況を確認して再度お試しください。',
      );
    }
  }

  String _localizeFunctionsError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'ログインの有効期限が切れています。再度サインインしてから送信してください。';
      case 'failed-precondition':
        return e.message ??
            'LINE の設定が未完了です。管理者に連絡してください。';
      case 'invalid-argument':
        return '送信内容が不正です（${e.message ?? ''}）。';
      case 'permission-denied':
        return '送信権限がありません。管理者に連絡してください。';
      case 'unavailable':
      case 'deadline-exceeded':
        return '通信に失敗しました。ネットワークを確認して再度お試しください。';
      default:
        return '送信に失敗しました（${e.code}）。${e.message ?? ''}';
    }
  }

  // ── 送信記録（Hive）──────────────────────────────────────────

  Future<void> _saveLog(NotificationLog log) async {
    await _box.put(log.boxKey, log);
  }

  /// テスト・手動記録用（UI からは使わない）
  @visibleForTesting
  Future<void> saveLogForTest(NotificationLog log) => _saveLog(log);

  /// 指定日・指定児童の送信記録（なければ null）
  NotificationLog? getLog(DateTime date, String customerId) =>
      _box.get(NotificationLog.makeBoxKey(_dateKey(date), customerId));

  /// 指定日・指定児童が既に通知済みか（クライアント側の二重送信判定）
  bool isAlreadyNotified(DateTime date, String customerId) {
    final log = getLog(date, customerId);
    return log != null && log.blocksResend;
  }

  /// 指定日の送信記録一覧（送信時刻の降順）
  List<NotificationLog> getLogsByDate(DateTime date) {
    final key = _dateKey(date);
    return _box.values.where((l) => l.dateKey == key).toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
  }

  /// 全送信記録（日付降順 → 送信時刻降順）
  List<NotificationLog> getAllLogs() {
    final all = _box.values.toList();
    all.sort((a, b) {
      final d = b.dateKey.compareTo(a.dateKey);
      return d != 0 ? d : b.sentAt.compareTo(a.sentAt);
    });
    return all;
  }

  /// 日付でグルーピングした送信記録（履歴画面用）
  Map<String, List<NotificationLog>> getLogsGroupedByDate() {
    final out = <String, List<NotificationLog>>{};
    for (final l in getAllLogs()) {
      out.putIfAbsent(l.dateKey, () => []).add(l);
    }
    return out;
  }

  /// 送信記録を削除する（誤記録の修復用。履歴画面から操作）
  Future<void> deleteLog(DateTime date, String customerId) async {
    await _box.delete(NotificationLog.makeBoxKey(_dateKey(date), customerId));
  }

  // ── LINE 連携コード ──────────────────────────────────────────

  /// 6 桁の連携コードを生成する
  ///
  /// 紛らわしい文字（0/O, 1/I/L）を除外し、電話・紙で伝えても
  /// 間違えにくい文字集合にする。
  static String generateCode([Random? rnd]) {
    const chars = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    final r = rnd ?? Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// 連携コードを発行し Firestore に保存する
  ///
  /// 戻り値: 発行したコード
  /// 失敗時は [VacancyLinkageException] を投げる。
  Future<String> issueLinkingCode({
    required String customerId,
    required String childName,
    String? issuedBy,
  }) async {
    if (!_remoteEnabled) {
      throw const VacancyLinkageException(
          'オフラインのため連携コードを発行できません。');
    }
    final now = DateTime.now();
    final expiresAt = now.add(linkingCodeTtl);

    // 衝突したら最大 5 回まで再生成
    for (int attempt = 0; attempt < 5; attempt++) {
      final code = generateCode();
      final ref =
          FirebaseFirestore.instance.collection(colLinkingCodes).doc(code);
      try {
        await ref.set({
          'code': code,
          'customerId': customerId,
          'childName': childName,
          'createdAt': Timestamp.fromDate(now),
          'expiresAt': Timestamp.fromDate(expiresAt),
          'issuedBy': issuedBy ?? '',
        });
        debugPrint('[VacancyNotification] linking code issued for $childName');
        return code;
      } on FirebaseException catch (e) {
        if (attempt == 4) {
          throw VacancyLinkageException(
              '連携コードの発行に失敗しました（${e.code}）。');
        }
      }
    }
    throw const VacancyLinkageException('連携コードの発行に失敗しました。');
  }

  /// Firestore の line_linkage を読んで、連携済み児童の lineUserId を
  /// Hive の Customer に反映する
  ///
  /// 【優先順位】
  /// line_linkage（保護者が LINE 上で実際に連携したもの）を
  /// Day 7 インポートの lineUserId より優先し、上書き保存する。
  /// インポート値は手入力・CSV 由来で誤りの可能性があるため。
  ///
  /// 戻り値: 更新した件数
  Future<LinkageSyncResult> syncLinkages() async {
    if (!_remoteEnabled) {
      throw const VacancyLinkageException('オフラインのため同期できません。');
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection(colLineLinkage)
          .get();

      int updated = 0;
      int unchanged = 0;
      int notFound = 0;

      for (final doc in snap.docs) {
        final data = doc.data();
        final customerId = (data['customerId'] ?? doc.id).toString();
        final lineUserId = (data['lineUserId'] ?? '').toString().trim();
        if (!isValidLineUserId(lineUserId)) continue;

        final customer = CustomerService.instance.getCustomerById(customerId);
        if (customer == null) {
          notFound++;
          continue;
        }
        if (customer.lineUserId == lineUserId) {
          unchanged++;
          continue;
        }
        customer.lineUserId = lineUserId;
        customer.updatedAt = DateTime.now();
        await CustomerService.instance.updateCustomer(customer);
        updated++;
      }

      final result = LinkageSyncResult(
        total: snap.docs.length,
        updated: updated,
        unchanged: unchanged,
        notFound: notFound,
      );
      debugPrint('[VacancyNotification] syncLinkages: $result');
      return result;
    } on FirebaseException catch (e) {
      throw VacancyLinkageException('連携状況の同期に失敗しました（${e.code}）。');
    }
  }

  /// 指定児童の連携を解除する（Firestore + Hive の lineUserId クリア）
  Future<void> unlink(String customerId) async {
    if (_remoteEnabled) {
      try {
        await FirebaseFirestore.instance
            .collection(colLineLinkage)
            .doc(customerId)
            .delete();
      } on FirebaseException catch (e) {
        throw VacancyLinkageException('連携解除に失敗しました（${e.code}）。');
      }
    }
    final customer = CustomerService.instance.getCustomerById(customerId);
    if (customer != null) {
      customer.lineUserId = null;
      customer.updatedAt = DateTime.now();
      await CustomerService.instance.updateCustomer(customer);
    }
    debugPrint('[VacancyNotification] unlinked: $customerId');
  }

  /// LINE userId の末尾 4 桁（表示・ログ用）
  static String? _suffix(String? lineUserId) {
    if (lineUserId == null || lineUserId.length < 4) return null;
    return lineUserId.substring(lineUserId.length - 4);
  }

  /// 表示用のマスク済み LINE userId（例: U...3f2a）
  static String maskLineUserId(String? lineUserId) {
    final s = _suffix(lineUserId);
    if (s == null) return '未連携';
    return 'U...$s';
  }
}

/// 連携コード発行・同期の失敗
class VacancyLinkageException implements Exception {
  final String message;
  const VacancyLinkageException(this.message);
  @override
  String toString() => message;
}

/// 連携状況同期の結果
@immutable
class LinkageSyncResult {
  final int total;
  final int updated;
  final int unchanged;
  final int notFound;

  const LinkageSyncResult({
    required this.total,
    required this.updated,
    required this.unchanged,
    required this.notFound,
  });

  String get summaryLabel {
    final parts = <String>['連携 $total件'];
    parts.add('更新 $updated件');
    if (unchanged > 0) parts.add('変更なし $unchanged件');
    if (notFound > 0) parts.add('該当児童なし $notFound件');
    return parts.join(' / ');
  }

  @override
  String toString() =>
      'LinkageSyncResult(total=$total, updated=$updated, '
      'unchanged=$unchanged, notFound=$notFound)';
}
