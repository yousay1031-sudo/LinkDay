import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
/// Hive の 'customers' ボックスをローカルストレージとして使用する。
///
/// TODO(SaaS): 将来 Firestore 同期する際は tenantId フィールド付きで
///             各ドキュメントに `tenantId` を付与し、
///             `customers/{tenantId}/customers/{customerId}` の
///             サブコレクション構造で同期する。
class CustomerService {
  CustomerService._();
  static final CustomerService instance = CustomerService._();

  static const String _boxName = 'customers';
  Box<Customer>? _box;

  Box<Customer> get _customers {
    assert(_box != null && _box!.isOpen, 'CustomerService.init() を先に呼び出してください');
    return _box!;
  }

  // ── 初期化 ──────────────────────────────────────────────────────────

  /// Hive ボックスを開く。main.dart で await して呼び出すこと。
  Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    _box = await Hive.openBox<Customer>(_boxName);
    debugPrint('[CustomerService] Hive box "$_boxName" opened. '
        'Stored: ${_box!.length} customers');
  }

  // ── 読み取り ────────────────────────────────────────────────────────

  /// 全顧客を返す。`includeInactive` が false（デフォルト）なら在籍中のみ。
  List<Customer> getAllCustomers({bool includeInactive = false}) {
    final all = _customers.values.toList();
    if (includeInactive) return all;
    return all.where((c) => c.isActive).toList()
      ..sort((a, b) => a.nameKana.compareTo(b.nameKana));
  }

  /// ID で顧客を取得する。見つからなければ null。
  Customer? getCustomerById(String id) {
    try {
      return _customers.values.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── 書き込み ────────────────────────────────────────────────────────

  /// 顧客を新規追加する
  Future<void> addCustomer(Customer customer) async {
    await _customers.put(customer.id, customer);
    debugPrint('[CustomerService] Added: ${customer.name} (${customer.id})');
  }

  /// 顧客情報を更新する
  Future<void> updateCustomer(Customer customer) async {
    final updated = customer.copyWith(); // updatedAt を現在時刻に更新
    await _customers.put(updated.id, updated);
    debugPrint('[CustomerService] Updated: ${updated.name} (${updated.id})');
  }

  /// 論理削除（isActive を false にする）
  Future<void> deleteCustomer(String id) async {
    final customer = getCustomerById(id);
    if (customer == null) return;
    final deleted = Customer(
      id: customer.id,
      name: customer.name,
      nameKana: customer.nameKana,
      birthday: customer.birthday,
      gender: customer.gender,
      phone: customer.phone,
      lineUserId: customer.lineUserId,
      guardianName: customer.guardianName,
      guardianPhone: customer.guardianPhone,
      recipientCertNumber: customer.recipientCertNumber,
      recipientCertExpiry: customer.recipientCertExpiry,
      monthlyAvailableDays: customer.monthlyAvailableDays,
      currentMonthUsedDays: customer.currentMonthUsedDays,
      regularDays: List.from(customer.regularDays),
      transportLocations: List.from(customer.transportLocations),
      notes: customer.notes,
      createdAt: customer.createdAt,
      updatedAt: DateTime.now(),
      isActive: false, // 論理削除
    );
    await _customers.put(id, deleted);
    debugPrint('[CustomerService] Deleted (logical): ${customer.name} ($id)');
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

  /// 月初に全顧客の当月利用日数を 0 にリセットする
  Future<void> resetMonthlyUsedDays() async {
    final all = _customers.values.toList();
    for (final customer in all) {
      if (customer.currentMonthUsedDays != 0) {
        final reset = Customer(
          id: customer.id,
          name: customer.name,
          nameKana: customer.nameKana,
          birthday: customer.birthday,
          gender: customer.gender,
          phone: customer.phone,
          lineUserId: customer.lineUserId,
          guardianName: customer.guardianName,
          guardianPhone: customer.guardianPhone,
          recipientCertNumber: customer.recipientCertNumber,
          recipientCertExpiry: customer.recipientCertExpiry,
          monthlyAvailableDays: customer.monthlyAvailableDays,
          currentMonthUsedDays: 0, // リセット
          regularDays: List.from(customer.regularDays),
          transportLocations: List.from(customer.transportLocations),
          notes: customer.notes,
          createdAt: customer.createdAt,
          updatedAt: DateTime.now(),
          isActive: customer.isActive,
        );
        await _customers.put(customer.id, reset);
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

// TODO(SaaS): 将来 Firestore 同期する際は tenantId フィールド付きで sync する
// 例: customers/{tenantId}/customers/{customerId}
// CustomerService に syncToFirestore(String tenantId) メソッドを追加する
