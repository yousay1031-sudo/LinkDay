import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/audit.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/pending_echoes.dart';
import '../data/staff_session.dart';
import '../models/customer.dart';
import '../utils/kana_util.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ImportConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Excel インポート時の設定
class ImportConfig {
  /// Excelカラム名 → Customer フィールド名 のマッピング
  /// 例: {'氏名': 'name', 'ふりがな': 'nameKana', ...}
  final Map<String, int> columnMapping;

  /// ひらがな・半角カナを全角カタカナに自動変換するか
  final bool autoKana;

  /// 氏名が重複するレコードをスキップするか
  final bool skipDuplicates;

  const ImportConfig({
    required this.columnMapping,
    this.autoKana = true,
    this.skipDuplicates = true,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ImportResult
// ─────────────────────────────────────────────────────────────────────────────

/// Excel インポートの結果
class ImportResult {
  final int success;
  final int failed;
  final List<String> errors;

  const ImportResult({
    required this.success,
    required this.failed,
    required this.errors,
  });

  bool get hasErrors => errors.isNotEmpty;
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomerService
// ─────────────────────────────────────────────────────────────────────────────

/// 顧客データのCRUD・検索・インポートを担うサービスクラス
///
/// シングルトンパターン: `CustomerService.instance` でアクセスする。
///
/// 保存先: Firestore `facilities/{facilityId}/customers/{customerId}`。
/// - ログイン後に [attach] でコレクション全体を購読し、端末内に一覧を持つ。
///   読み取りは従来どおり同期（キャッシュから）。他端末の変更は購読で届き、
///   [ChangeNotifier] で画面へ知らせる。
/// - 書き込みはキャッシュへ先に反映し、送信は待たずに戻る（オフラインで画面が
///   止まらないように。失敗は [DataErrors] で知らせる）。
/// - 更新は「前回の内容と違う項目だけ」を書く。値が変わっていなければ書かない。
/// - 記録を変える操作には担当者が必要（未選択なら選択画面を出し、選ばれなければ
///   [StaffNotSelectedException]）。自動処理は [AuditStamp.auto] を渡す。
/// - 顧客は削除しない（在籍終了 = isActive:false。[restoreCustomer] で戻せる）。
class CustomerService extends ChangeNotifier {
  CustomerService._();
  static final CustomerService instance = CustomerService._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// 画面へ渡す顧客（呼び出し側が書き換えてから update することがある）
  final Map<String, Customer> _cache = {};

  /// 最後に保存先と一致していた内容（差分の基準。画面側の書き換えの影響を受けない）
  final Map<String, Map<String, dynamic>> _base = {};

  /// 自分の書き込みの遅れて届いた折り返し（古い内容）を見分ける
  final PendingEchoesByDoc _echoes = PendingEchoesByDoc();

  bool _attached = false;
  bool get isAttached => _attached;

  CollectionReference<Map<String, dynamic>> get _col =>
      FacilityContext.instance.col(FsPaths.customers);

  // ── 接続 ────────────────────────────────────────────────────────────

  /// 購読を開始し、最初のスナップショット（端末内キャッシュ由来でも可）を待つ。
  Future<void> attach({
    Duration firstSnapshotTimeout = const Duration(seconds: 10),
  }) async {
    await detach();
    _attached = true;
    final first = Completer<void>();
    _sub = _col.snapshots().listen((snap) {
      var changed = false;
      for (final ch in snap.docChanges) {
        final id = ch.doc.id;
        if (ch.type == DocumentChangeType.removed) {
          changed |= _cache.remove(id) != null;
          _base.remove(id);
          continue;
        }
        final data = ch.doc.data();
        if (data == null) continue;
        final c = Customer.fromFirestore(id, data);
        final normalized = c.toFirestoreData();
        // 自分の古い書き込みの折り返し（この後の書き込みが控えている）: 戻さない
        if (_echoes.isStaleEcho(id, normalized)) continue;
        final known = _base[id];
        final sameData =
            known != null && fsChangedFields(known, normalized).isEmpty;
        _base[id] = normalized;
        final current = _cache[id];
        if (sameData && current != null) {
          // 自分の書き込みの折り返し（内容は同じ）: 何も変えず、画面も更新しない
          continue;
        }
        _cache[id] = c;
        changed = true;
      }
      if (!first.isCompleted) first.complete();
      if (changed) notifyListeners();
    }, onError: (Object e) {
      DataErrors.report('顧客情報を読み込めませんでした（${DataErrors.describe(e)}）');
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(firstSnapshotTimeout, onTimeout: () {
      debugPrint('[CustomerService] first snapshot timeout（オフラインの可能性）');
    });
    debugPrint('[CustomerService] attached: ${_cache.length} customers');
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _cache.clear();
    _base.clear();
    _echoes.clear();
    _attached = false;
  }

  // ── 読み取り ────────────────────────────────────────────────────────

  /// 全顧客を返す。`includeInactive` が false（デフォルト）なら在籍中のみ。
  List<Customer> getAllCustomers({bool includeInactive = false}) {
    final all = _cache.values.toList();
    if (includeInactive) return all;
    return all.where((c) => c.isActive).toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));
  }

  /// 在籍終了の顧客（ふりがな順）
  List<Customer> getInactiveCustomers() =>
      _cache.values.where((c) => !c.isActive).toList()
        ..sort((a, b) => a.nameKana.compareTo(b.nameKana));

  /// ID で顧客を取得する。見つからなければ null。
  Customer? getCustomerById(String id) => _cache[id];

  // ── 書き込み ────────────────────────────────────────────────────────

  /// 国レベル座標（「日本」等）の送迎場所座標を保存直前に破棄する
  ///
  /// Day 8 修正（受け入れ基準5）: どの経路（一括解決 / 個別採用 / 編集画面 /
  /// インポート）を通っても「日本」レベルの座標が保存されないよう、
  /// 永続化層で最終ガードする。該当時は unresolved に戻す。
  static int sanitizeCoords(Customer customer) {
    int dropped = 0;
    for (int i = 0; i < customer.transportLocations.length; i++) {
      final coord = customer.transportCoord(i);
      if (coord == null) continue;
      final formatted = (customer.transportFormatted(i) ?? '').trim();
      final types = customer.transportTypes(i);
      final isCountry = types.contains('country') ||
          formatted == '日本' ||
          formatted == '日本国' ||
          formatted == 'Japan';
      if (!isCountry) continue;
      debugPrint('[CustomerService] 国レベル座標を破棄: ${customer.name}'
          '[$i] "${customer.transportLocations[i]}" → "$formatted" '
          '(${coord.lat.toStringAsFixed(5)}, ${coord.lng.toStringAsFixed(5)})');
      customer.setTransportCoord(i, null, null, Customer.locUnresolved);
      dropped++;
    }
    return dropped;
  }

  /// 顧客を新規追加する
  ///
  /// [stamp] を省略すると担当者を求める（未選択なら選択画面）。
  Future<void> addCustomer(Customer customer, {AuditStamp? stamp}) async {
    final s = stamp ?? await StaffSession.instance.requireStamp();
    sanitizeCoords(customer);
    final data = customer.toFirestoreData();
    _cache[customer.id] = customer;
    _base[customer.id] = data;
    _echoes.add(customer.id, data);
    notifyListeners();
    DataErrors.send(
      _col.doc(customer.id).set({...data, ...s.toCreateFields()}),
      what: '顧客「${customer.name}」',
    );
    debugPrint('[CustomerService] Added: ${customer.name} (${customer.id}) by $s');
  }

  /// 顧客情報を更新する（前回の内容と違う項目だけを書く。違いが無ければ書かない）
  ///
  /// [stamp] を省略すると担当者を求める。自動処理は [AuditStamp.auto] を渡す。
  Future<void> updateCustomer(Customer customer, {AuditStamp? stamp}) async {
    sanitizeCoords(customer);
    final data = customer.toFirestoreData();
    final base = _base[customer.id];
    final changed = fsChangedFields(base, data);
    if (base != null && changed.isEmpty) {
      _cache[customer.id] = customer;
      return;
    }
    final s = stamp ?? await StaffSession.instance.requireStamp();
    customer.updatedAt = DateTime.now();
    _cache[customer.id] = customer;
    _base[customer.id] = data;
    _echoes.add(customer.id, data);
    notifyListeners();
    final ref = _col.doc(customer.id);
    DataErrors.send(
      base == null
          // 端末の一覧に無い顧客（読み込み前など）: 全項目を書く（作成日時は付けない）
          ? ref.set({...data, ...s.toFields()}, SetOptions(merge: true))
          : ref.update({...changed, ...s.toFields()}),
      what: '顧客「${customer.name}」',
    );
    debugPrint('[CustomerService] Updated: ${customer.name} (${customer.id}) '
        '${changed.keys.toList()} by $s');
  }

  /// 在籍終了にする（isActive=false。データは消さない。[restoreCustomer] で戻せる）
  Future<void> deleteCustomer(String id) => _setActive(id, false);

  /// 在籍終了の顧客を在籍中に戻す
  Future<void> restoreCustomer(String id) => _setActive(id, true);

  /// 在籍の切り替え（isActive と在籍終了日時だけを書く。他の項目には触れない）
  Future<void> _setActive(String id, bool active) async {
    final customer = _cache[id];
    if (customer == null || customer.isActive == active) return;
    final s = await StaffSession.instance.requireStamp();
    customer
      ..isActive = active
      ..deactivatedAt = active ? null : DateTime.now()
      ..updatedAt = DateTime.now();
    final base = _base[id];
    if (base != null) {
      _base[id] = {...base, Customer.fIsActive: active};
      _echoes.add(id, _base[id]!);
    }
    notifyListeners();
    DataErrors.send(
      _col.doc(id).update({
        Customer.fIsActive: active,
        Customer.fDeactivatedAt: active ? null : FieldValue.serverTimestamp(),
        ...s.toFields(),
      }),
      what: '顧客「${customer.name}」の${active ? '在籍に戻す操作' : '在籍終了'}',
    );
    debugPrint('[CustomerService] ${active ? 'Restored' : 'Deactivated'}: '
        '${customer.name} ($id) by $s');
  }

  /// テスト用: 購読せずにキャッシュだけ入れる（保存先には書かない）
  @visibleForTesting
  void debugSetCache(List<Customer> customers) {
    _cache
      ..clear()
      ..addEntries(customers.map((c) => MapEntry(c.id, c)));
    _base
      ..clear()
      ..addEntries(customers.map((c) => MapEntry(c.id, c.toFirestoreData())));
    notifyListeners();
  }

  // ── 検索 ────────────────────────────────────────────────────────────

  /// 氏名・ふりがな・電話番号・LINE ID から部分一致検索
  /// 大文字小文字・全角半角を問わない
  List<Customer> searchCustomers(String query) {
    if (query.trim().isEmpty) return getAllCustomers();
    final q = query.trim().toLowerCase();
    return getAllCustomers().where((c) {
      return c.name.toLowerCase().contains(q) ||
          c.nameKana.toLowerCase().contains(q) ||
          // カタカナ→ひらがな変換して検索クエリとも比較
          KanaUtil.katakanaToHiragana(c.nameKana).contains(
              KanaUtil.katakanaToHiragana(q)) ||
          (c.phone?.contains(q) ?? false) ||
          (c.lineUserId?.toLowerCase().contains(q) ?? false) ||
          (c.guardianName?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  // ── アラート ────────────────────────────────────────────────────────

  /// 受給者証期限が `daysThreshold` 日以内の在籍中顧客を返す
  /// 既に期限切れの顧客も含む（残日数 <= daysThreshold）
  List<Customer> getExpiringCertCustomers({int daysThreshold = 30}) {
    return getAllCustomers().where((c) {
      final days = c.certExpiryDaysLeft;
      return days != null && days <= daysThreshold;
    }).toList()
      ..sort((a, b) {
        final da = a.certExpiryDaysLeft ?? 9999;
        final db = b.certExpiryDaysLeft ?? 9999;
        return da.compareTo(db);
      });
  }

  // ── 月初リセット ─────────────────────────────────────────────────────

  /// 月初に全顧客の当月利用日数を 0 にリセットする（変わる項目だけを書く）
  Future<void> resetMonthlyUsedDays() async {
    final all = _cache.values.toList();
    for (final customer in all) {
      if (customer.currentMonthUsedDays != 0) {
        customer.currentMonthUsedDays = 0;
        await updateCustomer(customer);
      }
    }
    debugPrint('[CustomerService] Monthly used days reset for ${all.length} customers');
  }

  // ── Excel インポート ─────────────────────────────────────────────────

  /// Excel の行データから顧客を一括インポートする
  ///
  /// [rows] は Excel のセルデータ（List<List<dynamic>>）
  /// [config] はカラムマッピングやオプション設定
  /// 先頭行（ヘッダー行）はスキップする
  Future<ImportResult> importFromExcel(
    List<List<dynamic>> rows,
    ImportConfig config,
  ) async {
    int success = 0;
    int failed = 0;
    final errors = <String>[];

    // ヘッダー行をスキップ（インデックス 0）
    final dataRows = rows.length > 1 ? rows.sublist(1) : [];

    // 重複チェック用: 既存顧客の氏名セット
    final existingNames = config.skipDuplicates
        ? getAllCustomers(includeInactive: true).map((c) => c.name).toSet()
        : <String>{};

    for (var i = 0; i < dataRows.length; i++) {
      final rowIndex = i + 2; // Excelは1-indexed、ヘッダーが1行目
      final row = dataRows[i] as List<dynamic>;

      try {
        // ── 氏名（必須）
        final nameCol = config.columnMapping['name'];
        final name = nameCol != null && nameCol < row.length
            ? row[nameCol]?.toString().trim() ?? ''
            : '';
        if (name.isEmpty) {
          errors.add('行$rowIndex: 氏名が空です。スキップしました。');
          failed++;
          continue;
        }

        // ── 重複チェック
        if (config.skipDuplicates && existingNames.contains(name)) {
          errors.add('行$rowIndex: "$name" は既に登録されています。スキップしました。');
          failed++;
          continue;
        }

        // ── ふりがな（必須）
        final kanaCol = config.columnMapping['nameKana'];
        var nameKana = kanaCol != null && kanaCol < row.length
            ? row[kanaCol]?.toString().trim() ?? ''
            : '';
        if (nameKana.isEmpty) {
          // ふりがなが空の場合、氏名をそのまま使用
          nameKana = name;
        }
        if (config.autoKana) {
          nameKana = KanaUtil.normalizeKana(nameKana);
        }

        // ── 任意フィールドの取り出しヘルパー
        String? getCol(String fieldName) {
          final col = config.columnMapping[fieldName];
          if (col == null || col >= row.length) return null;
          final val = row[col]?.toString().trim();
          return (val?.isEmpty ?? true) ? null : val;
        }

        // ── 生年月日
        DateTime? birthday;
        final birthdayStr = getCol('birthday');
        if (birthdayStr != null) {
          birthday = _parseDate(birthdayStr);
        } else {
          final col = config.columnMapping['birthday'];
          if (col != null && col < row.length && row[col] is DateTime) {
            birthday = row[col] as DateTime;
          }
        }

        // ── 受給者証有効期限
        DateTime? certExpiry;
        final certExpiryStr = getCol('recipientCertExpiry');
        if (certExpiryStr != null) {
          certExpiry = _parseDate(certExpiryStr);
        } else {
          final col = config.columnMapping['recipientCertExpiry'];
          if (col != null && col < row.length && row[col] is DateTime) {
            certExpiry = row[col] as DateTime;
          }
        }

        // ── 月間支給量
        int monthlyDays = 23;
        final monthlyStr = getCol('monthlyAvailableDays');
        if (monthlyStr != null) {
          monthlyDays = int.tryParse(monthlyStr) ?? 23;
        }

        // ── 定期利用曜日（"月,水,金" のカンマ区切り）
        final List<int> regularDays = [];
        final regularStr = getCol('regularDays');
        if (regularStr != null) {
          regularDays.addAll(_parseRegularDays(regularStr));
        }

        // ── 送迎場所
        final transport1 = getCol('transportLocation1');
        final transport2 = getCol('transportLocation2');
        final transport3 = getCol('transportLocation3');
        final transportLocations = [
          if (transport1 != null) transport1,
          if (transport2 != null) transport2,
          if (transport3 != null) transport3,
        ];

        // ── Customer 生成
        final customer = Customer(
          name: name,
          nameKana: nameKana,
          birthday: birthday,
          gender: getCol('gender'),
          phone: getCol('phone'),
          lineUserId: getCol('lineUserId'),
          guardianName: getCol('guardianName'),
          guardianPhone: getCol('guardianPhone'),
          recipientCertNumber: getCol('recipientCertNumber'),
          recipientCertExpiry: certExpiry,
          monthlyAvailableDays: monthlyDays,
          regularDays: regularDays,
          transportLocations: transportLocations,
          notes: getCol('notes'),
        );

        await addCustomer(customer);
        existingNames.add(name);
        success++;
      } catch (e) {
        errors.add('行$rowIndex: エラーが発生しました: $e');
        failed++;
      }
    }

    debugPrint('[CustomerService] Import complete: '
        'success=$success, failed=$failed');
    return ImportResult(success: success, failed: failed, errors: errors);
  }

  // ── プライベートヘルパー ───────────────────────────────────────────

  /// "2020/04/01" や "2020-04-01" 形式の文字列を DateTime に変換
  static DateTime? _parseDate(String text) {
    try {
      final normalized = text.replaceAll('/', '-').replaceAll('.', '-');
      return DateTime.parse(normalized);
    } catch (_) {
      return null;
    }
  }

  /// "月,水,金" のカンマ区切り文字列を曜日番号リストに変換
  static List<int> _parseRegularDays(String text) {
    const dayMap = {
      '月': 1, '月曜': 1, '月曜日': 1,
      '火': 2, '火曜': 2, '火曜日': 2,
      '水': 3, '水曜': 3, '水曜日': 3,
      '木': 4, '木曜': 4, '木曜日': 4,
      '金': 5, '金曜': 5, '金曜日': 5,
      '土': 6, '土曜': 6, '土曜日': 6,
    };
    final result = <int>[];
    for (final part in text.split(RegExp(r'[,、・\s]+'))) {
      final trimmed = part.trim();
      final num = dayMap[trimmed];
      if (num != null && !result.contains(num)) {
        result.add(num);
      }
    }
    result.sort();
    return result;
  }
}
