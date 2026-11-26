import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/pending_echoes.dart';
import '../data/data_errors.dart';
import '../data/facility_context.dart';
import '../data/fs_values.dart';
import '../data/staff_session.dart';
import '../models/app_settings.dart';
import 'maps_js_service.dart';
import 'maps_loader.dart';

// ── SharedPreferences キー ────────────────────────────────────
/// 旧キー（1キー方式）— マイグレーション用
const String _kLegacyApiKeyPref = 'google_maps_api_key';

/// Maps JavaScript API キー（地図表示用、リファラー制限 OK）
const String _kJsApiKeyPref = 'gmaps_js_key';

/// Maps REST API キー（Geocoding/Directions/DistanceMatrix 用、制限なし or IP制限）
const String _kRestApiKeyPref = 'gmaps_rest_key';

/// 設定サービス
/// - AppSettings は Firestore `facilities/{facilityId}/settings/app`（事業所で 1 件）。
///   ログイン後に [attach] で購読し、端末内に持つ。読み取りは従来どおり同期。
///   保存先にまだ無い間は既定値（[AppSettings] の既定）で動き、最初の保存で作られる。
///   他の端末の変更は購読で届き、[ChangeNotifier] で画面へ知らせる。
/// - 更新は「前回の内容と違う項目だけ」を書く。担当者が必要。
/// - **Google Maps API キーは SharedPreferences（端末ごと）のまま**。Firestore には置かない。
///
/// 【2キー方式】
/// - JS API キー  : Maps JavaScript API（地図表示） → リファラー制限 OK
/// - REST API キー: Geocoding / Directions / Distance Matrix → 制限なし or IP制限
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  AppSettings _settings = AppSettings();

  /// 最後に保存先と一致していた内容（null = 保存先にまだ無い）
  Map<String, dynamic>? _base;

  /// 送った内容の折り返しのうち、まだ届いていないもの（古い折り返しで戻さないため）
  final PendingEchoes _echoes = PendingEchoes();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  bool _attached = false;

  bool get isAttached => _attached;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FacilityContext.instance.col(FsPaths.settings).doc(FsPaths.settingsDocId);

  // ── 初期化 ──────────────────────────────────────────────────

  /// 起動時（ログイン前）に呼ぶ。端末に保存した API キーの移行だけを行う。
  Future<void> init() async {
    debugPrint('[SettingsService] initialized with defaults（ログイン後に事業所の設定を読み込む）');
    // 旧キー（1キー方式）からのマイグレーション
    await _migrateLegacyApiKey();
  }

  /// ログイン後に呼ぶ。事業所の設定を購読し、最初の読み込みを待つ。
  Future<void> attach() async {
    await detach();
    _attached = true;
    final first = Completer<void>();
    _sub = _doc.snapshots().listen((snap) {
      final data = snap.data();
      if (data == null) {
        _base = null;
      } else {
        final s = AppSettings.fromFirestore(data);
        final normalized = s.toFirestoreData();
        // 続けて保存したときの、前の保存の折り返し: 画面の内容はもう新しいので戻さない
        if (!_echoes.isStaleEcho(normalized)) {
          final same =
              _base != null && fsChangedFields(_base, normalized).isEmpty;
          _base = normalized;
          if (!same) {
            _settings = s;
            if (first.isCompleted) notifyListeners();
          }
        }
      }
      if (!first.isCompleted) {
        first.complete();
        notifyListeners();
      }
    }, onError: (Object e) {
      DataErrors.report('設定を読み込めませんでした（${DataErrors.describe(e)}）');
      if (!first.isCompleted) first.complete();
    });
    await first.future.timeout(const Duration(seconds: 10), onTimeout: () {
      debugPrint('[SettingsService] first snapshot timeout（オフラインの可能性）');
    });
    debugPrint('[SettingsService] attached: ${_base == null ? "既定値（未保存）" : "保存済みの設定"}');
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _base = null;
    _echoes.clear();
    _settings = AppSettings();
    _attached = false;
  }

  /// 変わった項目だけを保存する（担当者が必要）
  Future<void> _save(AppSettings updated, String what) async {
    final data = updated.toFirestoreData();
    final changed = fsChangedFields(_base, data);
    if (_base != null && changed.isEmpty) {
      _settings = updated;
      return;
    }
    final stamp = await StaffSession.instance.requireStamp();
    final isNew = _base == null;
    _settings = updated;
    _base = data;
    notifyListeners();
    if (!FacilityContext.instance.isAttached) return;
    _echoes.add(data);
    DataErrors.send(
      _doc.set(
        {...(isNew ? data : changed), ...(isNew ? stamp.toCreateFields() : stamp.toFields())},
        SetOptions(merge: true),
      ),
      what: '設定（$what）',
    );
  }

  /// テスト用: 保存先を使わずに設定を入れる
  @visibleForTesting
  void debugSetSettings(AppSettings settings) {
    _settings = settings;
    _base = settings.toFirestoreData();
    notifyListeners();
  }

  /// 旧 'google_maps_api_key' が残っている場合、
  /// JS キーと REST キーの両方に複製してから旧キーを削除する
  Future<void> _migrateLegacyApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_kLegacyApiKeyPref);
    if (legacy == null || legacy.isEmpty) return;

    final jsKey = prefs.getString(_kJsApiKeyPref);
    final restKey = prefs.getString(_kRestApiKeyPref);

    // 新キーがまだ未設定の場合だけコピー
    if ((jsKey == null || jsKey.isEmpty)) {
      await prefs.setString(_kJsApiKeyPref, legacy);
      debugPrint('[SettingsService] migrated legacy key → JS key');
    }
    if ((restKey == null || restKey.isEmpty)) {
      await prefs.setString(_kRestApiKeyPref, legacy);
      debugPrint('[SettingsService] migrated legacy key → REST key');
    }

    // 旧キーを削除
    await prefs.remove(_kLegacyApiKeyPref);
    debugPrint('[SettingsService] legacy API key removed');
  }

  // ── 取得 ────────────────────────────────────────────────────

  /// 現在の設定を返す（なければデフォルト）
  AppSettings getSettings() => _settings;

  // ── 更新メソッド ─────────────────────────────────────────────

  /// 事業所情報を更新する
  /// 住所が変わった場合は緯度経度をクリアする
  Future<void> updateFacility(String name, String address) async {
    final current = getSettings();
    final addressChanged = current.facilityAddress != address;
    final updated = AppSettings(
      facilityName: name,
      facilityAddress: address,
      // 住所変更時は Geocoding キャッシュをクリア
      facilityLat: addressChanged ? null : current.facilityLat,
      facilityLng: addressChanged ? null : current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      // Day 11: 新フィールドを引き継ぐ（落とすと通知設定が既定値に戻る）
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '事業所情報');
    debugPrint('[SettingsService] facility updated: $name');
  }

  /// 車両設定を更新する
  Future<void> updateVehicles(
    int count,
    List<String> names,
    List<int> capacities,
  ) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: count,
      vehicleNames: names,
      vehicleCapacities: capacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      // Day 11: 新フィールドを引き継ぐ（落とすと通知設定が既定値に戻る）
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '車両');
    debugPrint('[SettingsService] vehicles updated: count=$count');
  }

  /// 運営時間・最大利用者数を更新する
  Future<void> updateOperatingHours(
    String pickupStart,
    String dropoffEnd,
    int maxStudents,
  ) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: maxStudents,
      defaultPickupStart: pickupStart,
      defaultDropoffEnd: dropoffEnd,
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '運営時間');
    debugPrint('[SettingsService] operating hours updated');
  }

  /// Geocoding 結果をキャッシュとして保存する
  Future<void> saveFacilityGeocode(double lat, double lng) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: lat,
      facilityLng: lng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      // Day 11: 新フィールドを引き継ぐ（落とすと通知設定が既定値に戻る）
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '事業所の位置');
    debugPrint('[SettingsService] geocode saved: $lat, $lng');
  }

  // ── Day 14: 空き枠の応募受付時間 ──────────────────────────────

  /// 応募の受付時間（時間）を更新する。範囲外は 1〜24 に丸める。
  /// 他の設定は一切変更しない。
  Future<void> updateSlotTtlHours(int hours) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: AppSettings.clampSlotTtlHours(hours),
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, 'LINE応募の受付時間');
    debugPrint('[SettingsService] slotTtlHours updated: ${updated.slotTtlHours}');
  }

  // ── Day 15: 管理者 LINE userId ────────────────────────────────

  /// 管理者の LINE userId を保存する。他の設定は一切変更しない。
  ///
  /// - 空・空白のみ → 未設定（null）として保存（通知を止める操作）
  /// - 形式不正（'U' + 32桁 16進でない）→ 保存せず false を返す
  ///   （誤った宛先を保存して、別人や存在しない宛先へ送るのを防ぐ）
  /// - 正しい形式 → trim して保存し true
  Future<bool> updateAdminLineUserId(String? value) async {
    final normalized = AppSettings.normalizeAdminLineUserId(value);
    if (normalized != null && !AppSettings.isValidLineUserId(normalized)) {
      return false;
    }
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: normalized,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '管理者 LINE userId');
    // 生の userId はログに出さない（設定有無のみ）
    debugPrint(
        '[SettingsService] adminLineUserId ${normalized == null ? "cleared" : "saved"}');
    return true;
  }

  // ── Day 11: 空き枠 LINE 通知設定 ─────────────────────────────

  /// 空き枠通知の回答期限時刻・文面テンプレートを更新する
  ///
  /// [deadline] は "HH:mm"。不正な値は既定値にフォールバックする。
  Future<void> updateVacancyNotice({
    required String deadline,
    required String template,
  }) async {
    final current = getSettings();
    final safeDeadline =
        isValidTimeString(deadline) ? deadline : AppSettings.defaultVacancyReplyDeadline;
    final safeTemplate = template.trim().isEmpty
        ? AppSettings.defaultVacancyMessageTemplate
        : template;

    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      vacancyReplyDeadline: safeDeadline,
      vacancyMessageTemplate: safeTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      journalActivityOptions: current.journalActivityOptions,
    );
    await _save(updated, '空き枠通知');
    debugPrint('[SettingsService] vacancy notice updated: deadline=$safeDeadline');
  }

  /// 業務日誌「その日の内容」の選択肢を保存する（担当者が必要）。
  /// 空・重複・長すぎるものは除く（[AppSettings.normalizeJournalActivityOptions]）。
  Future<void> updateJournalActivityOptions(List<String> options) async {
    final current = getSettings();
    final updated = AppSettings(
      facilityName: current.facilityName,
      facilityAddress: current.facilityAddress,
      facilityLat: current.facilityLat,
      facilityLng: current.facilityLng,
      vehicleCount: current.vehicleCount,
      vehicleNames: current.vehicleNames,
      vehicleCapacities: current.vehicleCapacities,
      maxStudentsPerDay: current.maxStudentsPerDay,
      defaultPickupStart: current.defaultPickupStart,
      defaultDropoffEnd: current.defaultDropoffEnd,
      vacancyReplyDeadline: current.vacancyReplyDeadline,
      vacancyMessageTemplate: current.vacancyMessageTemplate,
      slotTtlHours: current.slotTtlHours,
      adminLineUserId: current.adminLineUserId,
      staffPinEnabled: current.staffPinEnabled,
      journalActivityOptions: options,
    );
    await _save(updated, '業務日誌の内容の選択肢');
  }

  /// "HH:mm" 形式として妥当か
  static bool isValidTimeString(String v) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v.trim());
    if (m == null) return false;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    return h >= 0 && h <= 23 && min >= 0 && min <= 59;
  }

  // ── 2キー方式: JS API キー ───────────────────────────────────

  /// Maps JavaScript API キーを保存（地図表示用）
  Future<void> saveJsApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kJsApiKeyPref, key.trim());
    debugPrint('[SettingsService] JS API key saved');
  }

  /// Maps JavaScript API キーを読み出す
  Future<String?> loadJsApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kJsApiKeyPref);
    return (key != null && key.isNotEmpty) ? key : null;
  }

  /// Maps JavaScript API キーをクリア
  Future<void> clearJsApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kJsApiKeyPref);
    debugPrint('[SettingsService] JS API key cleared');
  }

  /// Maps JavaScript API キーが設定済みか
  Future<bool> hasJsApiKey() async {
    final key = await loadJsApiKey();
    return key != null && key.isNotEmpty;
  }

  // ── REST API キー（後方互換エイリアス）──────────────────────
  // RESTキー方式は廃止。内部的に JS キーに委譲する。

  /// @deprecated JSキー方式に統一。内部的に saveJsApiKey() を呼ぶ
  Future<void> saveRestApiKey(String key) => saveJsApiKey(key);

  /// @deprecated JSキー方式に統一。内部的に loadJsApiKey() を呼ぶ
  Future<String?> loadRestApiKey() => loadJsApiKey();

  /// @deprecated JSキー方式に統一。内部的に clearJsApiKey() を呼ぶ
  Future<void> clearRestApiKey() => clearJsApiKey();

  /// @deprecated JSキー方式に統一。内部的に hasJsApiKey() を呼ぶ
  Future<bool> hasRestApiKey() => hasJsApiKey();

  // ── 後方互換: 旧 loadApiKey / saveApiKey ────────────────────
  // すべて loadJsApiKey / saveJsApiKey に委譲

  /// @deprecated 代わりに loadJsApiKey() を使ってください
  Future<String?> loadApiKey() => loadJsApiKey();

  /// @deprecated 代わりに saveJsApiKey() を使ってください
  Future<void> saveApiKey(String key) => saveJsApiKey(key);

  /// @deprecated 代わりに clearJsApiKey() を使ってください
  Future<void> clearApiKey() => clearJsApiKey();

  /// @deprecated 代わりに hasJsApiKey() を使ってください
  Future<bool> hasApiKey() => hasJsApiKey();

  // ── Geocoding ────────────────────────────────────────────────

  /// Geocoding 用住所の正規化
  ///
  /// - 郵便番号（〒xxx-xxxx または xxx-xxxx）を除去
  /// - 階数情報（x階 / xF / x階部分）を除去（建物全体のマッチング向上）
  /// - 前後空白を除去
  /// - 表示用住所は元の文字列を維持
  static String normalizeAddressForGeocode(String address) {
    var normalized = address.trim();

    // 郵便番号除去: 〒080-0015 / 080-0015
    normalized = normalized.replaceAll(RegExp(r'〒?\d{3}-\d{4}\s*'), '');

    // 階数情報除去: " 2階" / " 2F" / " B1F" など（数字+階 or F）
    // スペースが前に付くパターンを優先除去
    normalized = normalized.replaceAll(
        RegExp(r'\s+[Bb]?\d+[Ff階]\s*$'), '');
    normalized = normalized.replaceAll(
        RegExp(r'\s+[Bb]?\d+[Ff階][^\s]*\s*$'), '');

    // 号室表示除去: " 201号室" / " 101"（末尾の数字のみのパターン）
    normalized = normalized.replaceAll(RegExp(r'\s+\d+号室\s*$'), '');

    // 前後空白除去
    normalized = normalized.trim();

    debugPrint('[SettingsService] normalizeAddress: "$address" → "$normalized"');
    return normalized;
  }

  /// 事業所住所を Geocoding して座標を保存する（JS Interop 版）
  ///
  /// - 住所文字列を正規化してから geocode する
  /// - 成功時は必ず設定（Firestore）に上書き保存する
  /// - [address] を指定すると Hive の facilityAddress より優先する
  Future<({double lat, double lng})> geocodeFacility({
    String? address,
  }) async {
    final key = await loadJsApiKey();
    if (key == null || key.isEmpty) {
      throw Exception('Google Maps API キーが設定されていません。設定画面で入力してください。');
    }
    final settings = getSettings();
    final rawAddress = address ?? settings.facilityAddress;

    // 住所を正規化（階数・郵便番号除去）
    final geocodeAddress = normalizeAddressForGeocode(rawAddress);
    if (geocodeAddress.isEmpty) {
      throw Exception('住所が空です。設定画面で住所を入力してください。');
    }

    debugPrint('[SettingsService] geocodeFacility: '
        'raw="$rawAddress" → normalized="$geocodeAddress"');

    // JS Interop 経由で Geocoder を呼ぶ
    final result = await MapsJsService.instance.geocodeAddress(geocodeAddress);

    debugPrint('[SettingsService] geocodeFacility result: '
        'lat=${result.lat}, lng=${result.lng} '
        '(address="$geocodeAddress")');

    // 必ず上書き保存（旧座標を確実に更新）
    await saveFacilityGeocode(result.lat, result.lng);

    return (lat: result.lat, lng: result.lng);
  }

  /// 緯度経度を手動で保存する（地図上でマーカーをドラッグ後に呼ぶ）
  Future<void> saveFacilityLatLng(double lat, double lng) async {
    await saveFacilityGeocode(lat, lng);
    debugPrint('[SettingsService] saveFacilityLatLng: '
        'lat=${lat.toStringAsFixed(7)}, lng=${lng.toStringAsFixed(7)}');
  }

  // ── テスト ────────────────────────────────────────────────────

  /// API キーのテスト（MapsLoader でロード → Geocoder で事業所住所を変換）
  Future<ApiKeyStatus> testJsApiKey(String key) async {
    if (key.isEmpty) return ApiKeyStatus.notSet;
    try {
      // 1. Maps JS API をロード
      MapsLoader.reset(); // キー変更を反映するためリセット
      await MapsLoader.ensureLoaded(key);

      // 2. Geocoder で事業所住所を変換して有効性を確認
      final settings = getSettings();
      await MapsJsService.instance.geocodeAddress(settings.facilityAddress);

      debugPrint('[SettingsService] JS API key test succeeded');
      return ApiKeyStatus.valid;
    } catch (e) {
      debugPrint('[SettingsService] JS API key test failed: $e');
      return ApiKeyStatus.invalid;
    }
  }

  /// @deprecated 代わりに testJsApiKey() を使ってください
  Future<ApiKeyStatus> testRestApiKey(String key) => testJsApiKey(key);

  /// @deprecated 代わりに testJsApiKey() を使ってください
  Future<ApiKeyStatus> testApiKey(String key) => testJsApiKey(key);
}

/// API キーの状態
enum ApiKeyStatus {
  notSet,   // 未設定
  valid,    // 有効（または形式OK）
  invalid,  // 無効・エラー
}

