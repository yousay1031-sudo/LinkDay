import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_settings.dart';
import '../services/app_version.dart';
import '../verify/verify_config.dart';
import '../verify/verify_faults.dart';
import '../data/staff_session.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/unfocus_offscreen_text_field.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/motion/skeleton_gate.dart';
import '../widgets/motion/success_feedback.dart';
import '../widgets/skeletons/screen_skeletons.dart';
import '../widgets/draggable_marker_map.dart';
import '../widgets/motion/app_spinner.dart';

/// 設定のアプリ情報に出す Flutter の版。
/// flutter build / run / test がビルド時に自動で埋める FlutterVersion を使う
/// （以前は手で書いた「Flutter 3.35.4」のままで、実際の版とずれていた）。
/// 埋まっていないビルド（独自の組み込み等）では「不明」。
const String frameworkVersionLabel =
    'Flutter ${FlutterVersion.version ?? '（不明）'}';

// ════════════════════════════════════════════════════════════════
// SettingsScreen
// ════════════════════════════════════════════════════════════════
class SettingsScreen extends StatefulWidget {
  /// テスト用: APIキーの読込処理を差し替える（読込失敗の再現用）。
  /// 本番では常に null（SettingsService.loadJsApiKey を使う）。
  @visibleForTesting
  final Future<String?> Function()? debugLoadJsApiKey;

  const SettingsScreen({super.key, this.debugLoadJsApiKey});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ── コントローラー ────────────────────────────────────────────
  final _facilityNameCtrl = TextEditingController();

  /// Day 15: 管理者 LINE userId の入力欄
  final _adminLineUserIdCtrl = TextEditingController();
  String? _adminLineUserIdError;
  final _facilityAddressCtrl = TextEditingController();
  // 2キー方式
  final _jsApiKeyCtrl = TextEditingController(); // 共通 API キー（1つに統一）
  final _maxStudentsCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // ── 状態 ─────────────────────────────────────────────────────
  bool _jsApiKeyVisible = false;
  ApiKeyStatus _jsApiKeyStatus = ApiKeyStatus.notSet;
  bool _testingJsKey = false;
  bool _geocoding = false;
  int _vehicleCount = 2;
  final List<TextEditingController> _vehicleNameCtrls = [];
  final List<TextEditingController> _vehicleCapCtrls = [];
  TimeOfDay _pickupStart = const TimeOfDay(hour: 8, minute: 30);
  TimeOfDay _dropoffEnd = const TimeOfDay(hour: 16, minute: 30);

  /// Day 14: 空き枠の応募受付時間（時間）
  int _slotTtlHours = AppSettings.defaultSlotTtlHours;

  // ── 地図プレビュー状態 ─────────────────────────────────────────
  /// geocode 後に表示する事業所座標（マーカー位置・地図中心）
  double? _previewLat;
  double? _previewLng;

  /// 現在のマーカー位置（ドラッグ後に更新）
  LatLng? _markerLatLng;
  bool _savingPosition = false;

  /// API キー（非同期取得）の読込中。ここだけ骨格を出す
  bool _apiKeyLoading = true;
  String? _apiKeyLoadError;

  /// APIキーが「読めている」状態（読込中でも読込失敗でもない）。
  /// false の間は、読めていない値を空値で上書き・削除しないよう
  /// APIキーの保存・テスト・クリアを行わない。他の設定項目には影響しない。
  bool get _apiKeyReady => !_apiKeyLoading && _apiKeyLoadError == null;

  @override
  void initState() {
    super.initState();
    debugPrint('[SettingsScreen] initState start');
    // 初回 build で _vehicleNameCtrls[i] が範囲外にならないよう、
    // 同期で取得できる設定値はここで即時反映する。
    // （従来は postFrameCallback で遅延していたため、初回 build で
    //   車両コントローラが空のまま TextFormField を構築し NullError になっていた）
    final settings = SettingsService.instance.getSettings();
    _applySettingsSync(settings);
    debugPrint('[SettingsScreen] initState end: vehicleCount=$_vehicleCount, '
        'nameCtrls=${_vehicleNameCtrls.length}, capCtrls=${_vehicleCapCtrls.length}');
    // API キーは非同期読み込みのため後続フレームで反映
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  /// 画面に反映した設定（保存していない入力があるかの判定に使う）
  AppSettings? _applied;

  /// 入力欄の内容が [s] と同じか（保存していない入力が無いか）
  bool _formMatches(AppSettings s) {
    final names = _vehicleNameCtrls.map((c) => c.text.trim()).toList();
    final caps =
        _vehicleCapCtrls.map((c) => int.tryParse(c.text) ?? 5).toList();
    return _facilityNameCtrl.text.trim() == s.facilityName &&
        _facilityAddressCtrl.text.trim() == s.facilityAddress &&
        (int.tryParse(_maxStudentsCtrl.text) ?? -1) == s.maxStudentsPerDay &&
        _vehicleCount == s.vehicleCount.clamp(1, 5) &&
        listEquals(names, s.vehicleNames.take(_vehicleCount).toList()) &&
        listEquals(caps, s.vehicleCapacities.take(_vehicleCount).toList()) &&
        _formatTime(_pickupStart) == s.defaultPickupStart &&
        _formatTime(_dropoffEnd) == s.defaultDropoffEnd &&
        _adminLineUserIdCtrl.text.trim() == (s.adminLineUserId ?? '');
  }

  /// 他の端末（またはこの画面の保存）で設定が変わった
  void _onSettingsChanged() {
    if (!mounted) return;
    final latest = SettingsService.instance.getSettings();
    if (_formMatches(latest)) {
      // この画面で保存した内容の反映など: 入力欄はそのまま
      _applied = latest;
      setState(() =>
          _slotTtlHours = AppSettings.clampSlotTtlHours(latest.slotTtlHours));
      return;
    }
    final prev = _applied;
    if (prev == null || _formMatches(prev)) {
      // 保存していない入力は無い → 開き直さずに最新の内容を表示する
      setState(() => _applySettingsSync(latest));
      return;
    }
    // 入力中の内容は消さない（保存すると、その項目は入力した内容になる）
    _showSnack(
        '他の端末で設定が変更されました。保存していない入力があるため、画面には反映していません。', AppColors.warning);
  }

  /// 担当者の選択を閉じたら保存しない（true = 保存した）
  Future<bool> _saveWithStaff(Future<void> Function() save) async {
    try {
      await save();
      return true;
    } on StaffNotSelectedException {
      return false;
    }
  }

  /// 同期取得できる設定値をコントローラ・状態に反映する（setState なし）
  void _applySettingsSync(AppSettings settings) {
    _applied = settings;
    _facilityNameCtrl.text = settings.facilityName;
    _facilityAddressCtrl.text = settings.facilityAddress;
    _maxStudentsCtrl.text = settings.maxStudentsPerDay.toString();
    _vehicleCount = settings.vehicleCount.clamp(1, 5);
    _pickupStart = _parseTime(settings.defaultPickupStart);
    _dropoffEnd = _parseTime(settings.defaultDropoffEnd);
    _slotTtlHours = AppSettings.clampSlotTtlHours(settings.slotTtlHours);
    _adminLineUserIdCtrl.text = settings.adminLineUserId ?? '';
    _rebuildVehicleControllers(
        settings.vehicleNames, settings.vehicleCapacities);

    // 既存の geocode 済み座標があれば地図プレビューを初期表示
    final lat = settings.facilityLat;
    final lng = settings.facilityLng;
    if (lat != null && lng != null) {
      _previewLat = lat;
      _previewLng = lng;
      _markerLatLng = LatLng(lat, lng);
    }
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    _facilityNameCtrl.dispose();
    _adminLineUserIdCtrl.dispose();
    _facilityAddressCtrl.dispose();
    _jsApiKeyCtrl.dispose();
    _maxStudentsCtrl.dispose();
    for (final c in _vehicleNameCtrls) {
      c.dispose();
    }
    for (final c in _vehicleCapCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSettings({bool reapplySettings = true}) async {
    final settings = SettingsService.instance.getSettings();
    String? jsKey;
    try {
      if (VerifyConfig.enabled) {
        await VerifyFaults.apply(VerifyFaults.settings);
      }
      jsKey = await (widget.debugLoadJsApiKey ??
          SettingsService.instance.loadJsApiKey)();
    } catch (e) {
      debugPrint('[SettingsScreen] loadJsApiKey failed: $e');
      if (!mounted) return;
      // 骨格のまま放置しない: 入力欄を出して再読込できるようにする
      setState(() {
        _apiKeyLoading = false;
        _apiKeyLoadError = 'APIキーを読み込めませんでした';
      });
      return;
    }
    if (!mounted) return;

    debugPrint(
        '[SettingsScreen] _loadSettings: apiKey=${jsKey == null || jsKey.isEmpty ? "未設定" : "設定済み"}, '
        'facilityLatLng=${settings.hasGeocode ? "あり" : "未設定"}, '
        'vehicleCount=${settings.vehicleCount}');

    setState(() {
      // 再試行時は、読込失敗中に編集された他の設定項目を上書きしない
      if (reapplySettings) _applySettingsSync(settings);
      _jsApiKeyCtrl.text = jsKey ?? '';
      _jsApiKeyStatus = (jsKey != null && jsKey.isNotEmpty)
          ? ApiKeyStatus.valid
          : ApiKeyStatus.notSet;
      _apiKeyLoading = false;
      _apiKeyLoadError = null;
    });
  }

  void _retryLoadSettings() {
    setState(() {
      _apiKeyLoading = true;
      _apiKeyLoadError = null;
    });
    _loadSettings(reapplySettings: false);
  }

  void _rebuildVehicleControllers(List<String> names, List<int> caps) {
    for (final c in _vehicleNameCtrls) {
      c.dispose();
    }
    for (final c in _vehicleCapCtrls) {
      c.dispose();
    }
    _vehicleNameCtrls.clear();
    _vehicleCapCtrls.clear();

    for (int i = 0; i < _vehicleCount; i++) {
      _vehicleNameCtrls.add(TextEditingController(
        text: i < names.length ? names[i] : '車両${String.fromCharCode(65 + i)}',
      ));
      _vehicleCapCtrls.add(TextEditingController(
        text: (i < caps.length ? caps[i] : 5).toString(),
      ));
    }
  }

  // ── 保存処理 ─────────────────────────────────────────────────

  Future<void> _saveFacility() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final newAddress = _facilityAddressCtrl.text.trim();
    final prevSettings = SettingsService.instance.getSettings();
    final addressChanged = prevSettings.facilityAddress != newAddress;

    final saved =
        await _saveWithStaff(() => SettingsService.instance.updateFacility(
              _facilityNameCtrl.text.trim(),
              newAddress,
            ));
    if (!saved || !mounted) return;
    _showSnack('事業所情報を保存しました', AppColors.success);

    // 住所が変更された場合は自動でジオコーディングを実行
    if (addressChanged && newAddress.isNotEmpty) {
      final jsKey = _jsApiKeyCtrl.text.trim();
      if (!_apiKeyReady) {
        // APIキーが読めていない間は「未設定」と断定しない
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        _showSnack(
          '住所を変更しました。APIキーを読み込めていないため、緯度経度の自動取得は行っていません。',
          AppColors.warning,
        );
      } else if (jsKey.isNotEmpty) {
        // 少し遅延させてスナックバーが表示されてから実行
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        await _geocodeFacility();
      } else {
        // API キー未設定の場合はヒントを表示
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        _showSnack(
          '住所を変更しました。APIキーを設定すると緯度経度を自動取得できます。',
          AppColors.warning,
        );
      }
    }
  }

  Future<void> _saveVehicles() async {
    final names = _vehicleNameCtrls.map((c) => c.text.trim()).toList();
    final caps =
        _vehicleCapCtrls.map((c) => int.tryParse(c.text) ?? 5).toList();
    final saved = await _saveWithStaff(() =>
        SettingsService.instance.updateVehicles(_vehicleCount, names, caps));
    if (!saved || !mounted) return;
    _showSnack('車両設定を保存しました', AppColors.success);
  }

  Future<void> _saveOperatingHours() async {
    final maxStudents = int.tryParse(_maxStudentsCtrl.text) ?? 10;
    final saved = await _saveWithStaff(
        () => SettingsService.instance.updateOperatingHours(
              _formatTime(_pickupStart),
              _formatTime(_dropoffEnd),
              maxStudents,
            ));
    if (!saved || !mounted) return;
    _showSnack('運営時間を保存しました', AppColors.success);
  }

  Future<void> _saveSlotTtl(int hours) async {
    final v = AppSettings.clampSlotTtlHours(hours);
    setState(() => _slotTtlHours = v);
    final saved = await _saveWithStaff(
        () => SettingsService.instance.updateSlotTtlHours(v));
    if (!mounted) return;
    if (!saved) {
      // 担当者の選択を閉じた → 表示を保存先の値に戻す
      setState(() => _slotTtlHours = AppSettings.clampSlotTtlHours(
          SettingsService.instance.getSettings().slotTtlHours));
      return;
    }
    _showSnack('LINE応募の受付時間を$v時間に変更しました（次回の通知から有効）', AppColors.success);
  }

  /// Day 15: 管理者 LINE userId を保存する。
  /// 空欄は「未設定に戻す」、形式不正は保存せずエラー表示。
  Future<void> _saveAdminLineUserId() async {
    final text = _adminLineUserIdCtrl.text.trim();
    if (text.isNotEmpty && !AppSettings.isValidLineUserId(text)) {
      setState(() =>
          _adminLineUserIdError = 'userId の形式が正しくありません（U + 英数字32桁、計33文字）');
      return;
    }
    setState(() => _adminLineUserIdError = null);
    bool? ok;
    final saved = await _saveWithStaff(() async {
      ok = await SettingsService.instance.updateAdminLineUserId(text);
    });
    if (!saved || !mounted) return;
    if (ok != true) {
      _showSnack('管理者 userId を保存できませんでした', AppColors.error);
      return;
    }
    _showSnack(
      text.isEmpty ? '管理者通知を解除しました' : '管理者 userId を保存しました（次回の通知から有効）',
      AppColors.success,
    );
  }

  // ── API キー操作（1キー方式） ─────────────────────────────

  Future<void> _saveJsApiKey() async {
    if (!_apiKeyReady) return; // 読込中・読込失敗中は既存値に触れない
    final key = _jsApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('Google Maps API キーを入力してください', AppColors.error);
      return;
    }
    await SettingsService.instance.saveJsApiKey(key);
    if (!mounted) return;
    setState(() => _jsApiKeyStatus = ApiKeyStatus.valid);
    _showSnack('API キーを保存しました', AppColors.success);
  }

  Future<void> _testJsApiKey() async {
    if (!_apiKeyReady) return;
    final key = _jsApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('Google Maps API キーを入力してください', AppColors.error);
      return;
    }
    setState(() => _testingJsKey = true);
    try {
      final status = await SettingsService.instance.testJsApiKey(key);
      if (!mounted) return;
      setState(() => _jsApiKeyStatus = status);
      switch (status) {
        case ApiKeyStatus.valid:
          _showSnack(
              '✅ API キー有効（地図表示・ルート計算・ジオコーディングが動作します）', AppColors.success);
          break;
        case ApiKeyStatus.invalid:
          _showSnack('❌ API キーが無効です。キーの制限設定または権限を確認してください。', AppColors.error);
          break;
        case ApiKeyStatus.notSet:
          _showSnack('⚠️ API キーが未設定です', AppColors.warning);
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _jsApiKeyStatus = ApiKeyStatus.invalid);
      _showSnack('テスト失敗: $e', AppColors.error);
    } finally {
      if (mounted) setState(() => _testingJsKey = false);
    }
  }

  Future<void> _clearJsApiKey() async {
    if (!_apiKeyReady) return; // 読めていないキーを削除しない
    final confirmed = await _confirmClear('Google Maps API キー');
    if (confirmed != true || !mounted) return;
    await SettingsService.instance.clearJsApiKey();
    if (!mounted) return;
    setState(() {
      _jsApiKeyCtrl.clear();
      _jsApiKeyStatus = ApiKeyStatus.notSet;
    });
    _showSnack('API キーを削除しました', AppColors.warning);
  }

  Future<bool?> _confirmClear(String target) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('APIキーをクリア'),
        content: Text('$target を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  Future<void> _geocodeFacility() async {
    setState(() => _geocoding = true);
    try {
      // 現在の住所欄テキストで geocode（保存前でも最新の入力を使う）
      final address = _facilityAddressCtrl.text.trim();
      final result = await SettingsService.instance.geocodeFacility(
        address: address.isNotEmpty ? address : null,
      );
      if (!mounted) return;

      final latLng = LatLng(result.lat, result.lng);
      setState(() {
        _previewLat = result.lat;
        _previewLng = result.lng;
        _markerLatLng = latLng;
      });

      // カメラ移動は DraggableMarkerMap.didUpdateWidget が initialPosition 変化で行う

      _showSnack(
        '座標取得成功: ${result.lat.toStringAsFixed(7)}, ${result.lng.toStringAsFixed(7)}\n'
        '地図上でマーカーを確認・微調整してください',
        AppColors.success,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('取得失敗: $e', AppColors.error);
    } finally {
      if (mounted) {
        setState(() => _geocoding = false);
      }
    }
  }

  /// マーカーをドラッグした後に呼ばれる（地図プレビュー内）
  void _onMarkerDragged(LatLng newPosition) {
    setState(() {
      _markerLatLng = newPosition;
      _previewLat = newPosition.latitude;
      _previewLng = newPosition.longitude;
    });
    debugPrint('[SettingsScreen] marker dragged: '
        '${newPosition.latitude.toStringAsFixed(7)}, '
        '${newPosition.longitude.toStringAsFixed(7)}');
  }

  /// 「この位置を事業所に設定」ボタン
  Future<void> _saveMarkerPosition() async {
    final pos = _markerLatLng;
    if (pos == null) return;
    setState(() => _savingPosition = true);
    try {
      await SettingsService.instance.saveFacilityLatLng(
        pos.latitude,
        pos.longitude,
      );
      if (!mounted) return;
      _showSnack(
        '事業所位置を保存しました\n'
        '緯度: ${pos.latitude.toStringAsFixed(7)}\n'
        '経度: ${pos.longitude.toStringAsFixed(7)}',
        AppColors.success,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('保存失敗: $e', AppColors.error);
    } finally {
      if (mounted) setState(() => _savingPosition = false);
    }
  }

  /// Google Maps 検索で住所を別タブで確認（修正7）
  Future<void> _openInGoogleMaps() async {
    final address = _facilityAddressCtrl.text.trim();
    if (address.isEmpty) {
      _showSnack('住所を入力してください', AppColors.error);
      return;
    }
    final normalized = SettingsService.normalizeAddressForGeocode(address);
    final encoded = Uri.encodeComponent(normalized);
    final url = 'https://www.google.com/maps/search/?api=1&query=$encoded';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) _showSnack('Google Maps を開けませんでした', AppColors.error);
    }
  }

  // ── TimePicker ───────────────────────────────────────────────

  Future<void> _pickTime({
    required TimeOfDay initial,
    required void Function(TimeOfDay) onSelected,
    required String helpText,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: helpText,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked != null && mounted) {
      setState(() => onSelected(picked));
    }
  }

  // ── ユーティリティ ────────────────────────────────────────────

  TimeOfDay _parseTime(String s) {
    final parts = s.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
    );
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _showSnack(String message, Color color) {
    // 成功（緑）はチェックマーク付き。文言は呼び出し元のまま
    if (color == AppColors.success) {
      showSuccessSnack(context, message);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.controlBorderRadius)),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        actions: const [SizedBox(width: 8)],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          // 入力中の欄が画面の外に出たらフォーカスを外す（ブラウザで読み上げが
          // 有効なとき、戻ってきた入力欄の保存前の入力が消えるのを防ぐ）
          child: UnfocusOffscreenTextField(
            // 一度に全部を作る（ListView は画面外の部品を作り直すため、職員の名前など
            // 部品が自分で持つ入力欄の保存前の入力が、スクロールで消えていた）
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFacilitySection(),
                  const SizedBox(height: 16),
                  _buildVehicleSection(),
                  const SizedBox(height: 16),
                  _buildOperatingHoursSection(),
                  const SizedBox(height: 16),
                  _buildSlotTtlSection(),
                  const SizedBox(height: 16),
                  _buildAdminLineUserIdSection(),
                  const SizedBox(height: 16),
                  _buildApiKeySection(),
                  const SizedBox(height: 16),
                  _buildAppInfoSection(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── セクション: 事業所情報 ────────────────────────────────────

  Widget _buildFacilitySection() {
    return _SectionCard(
      title: '事業所情報',
      icon: Icons.business,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _facilityNameCtrl,
            decoration: const InputDecoration(
              labelText: '事業所名',
              prefixIcon: Icon(Icons.store),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? '事業所名は必須です' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _facilityAddressCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '事業所住所',
              prefixIcon: Icon(Icons.location_on),
              helperText: '「2階」などの階数・「〒」郵便番号は自動除去して座標検索します',
              helperMaxLines: 2,
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? '住所は必須です' : null,
          ),
          const SizedBox(height: 10),
          // 操作ボタン行: 座標取得 / G-Maps確認 / 保存
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              AppOutlinedButton.icon(
                onPressed: _geocoding ? null : _geocodeFacility,
                icon: _geocoding
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: AppSpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.gps_fixed, size: 16),
                label: Text(_geocoding ? '取得中...' : '座標を取得',
                    style: const TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              AppOutlinedButton.icon(
                onPressed: _openInGoogleMaps,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('G-Mapsで確認', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.info,
                  side: const BorderSide(color: AppColors.info),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              AppElevatedButton.icon(
                onPressed: _saveFacility,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ),
          // 地図プレビュー（geocode 成功後に表示）
          if (_previewLat != null && _previewLng != null) ...[
            const SizedBox(height: 16),
            _buildLocationMapPreview(),
          ],
        ],
      ),
    );
  }

  /// 事業所位置の地図プレビューウィジェット
  Widget _buildLocationMapPreview() {
    final lat = _previewLat;
    final lng = _previewLng;
    if (lat == null || lng == null) return const SizedBox.shrink();
    final center = LatLng(lat, lng);
    final marker = _markerLatLng ?? center;

    // 共通ウィジェット（送迎場所の微調整 UI と共有）
    return DraggableMarkerMap(
      initialPosition: marker,
      markerTitle:
          _facilityNameCtrl.text.isNotEmpty ? _facilityNameCtrl.text : '事業所',
      markerSnippet: _facilityAddressCtrl.text.trim(),
      hue: BitmapDescriptor.hueOrange,
      onPositionChanged: _onMarkerDragged,
      actionLabel: 'この位置を事業所に設定',
      actionIcon: Icons.place,
      actionBusy: _savingPosition,
      onAction: _saveMarkerPosition,
    );
  }

  // ── セクション: 車両管理 ─────────────────────────────────────

  Widget _buildVehicleSection() {
    return _SectionCard(
      title: '車両管理',
      icon: Icons.directions_car,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('車両台数: ', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _vehicleCount,
                items: List.generate(5, (i) => i + 1)
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n台')))
                    .toList(),
                onChanged: (n) {
                  if (n == null) return;
                  setState(() {
                    _vehicleCount = n;
                    final settings = SettingsService.instance.getSettings();
                    _rebuildVehicleControllers(
                      settings.vehicleNames,
                      settings.vehicleCapacities,
                    );
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ガード: コントローラ数と _vehicleCount が一致しない瞬間があっても
          // 範囲外アクセスしないよう、実在するコントローラ数で生成する
          ...List.generate(
              _vehicleCount < _vehicleNameCtrls.length
                  ? _vehicleCount
                  : (_vehicleNameCtrls.length < _vehicleCapCtrls.length
                      ? _vehicleNameCtrls.length
                      : _vehicleCapCtrls.length), (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _vehicleNameCtrls[i],
                      decoration: InputDecoration(
                        labelText: '車両${i + 1}の名前',
                        prefixIcon: const Icon(Icons.local_taxi, size: 18),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _vehicleCapCtrls[i],
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '定員（名）',
                        isDense: true,
                      ),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 1 || n > 20) {
                          return '1〜20';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
            );
          }),
          Align(
            alignment: Alignment.centerRight,
            child: AppElevatedButton.icon(
              key: const Key('saveVehiclesButton'),
              onPressed: _saveVehicles,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('車両設定を保存'),
            ),
          ),
        ],
      ),
    );
  }

  // ── セクション: 運営時間 ─────────────────────────────────────

  Widget _buildOperatingHoursSection() {
    return _SectionCard(
      title: '運営時間',
      icon: Icons.access_time,
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.directions_bus, color: AppColors.primary),
            title: const Text('通常お迎え開始時刻'),
            trailing: Text(
              _formatTime(_pickupStart),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
            onTap: () => _pickTime(
              initial: _pickupStart,
              onSelected: (t) => _pickupStart = t,
              helpText: 'お迎え開始時刻',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.home, color: AppColors.secondary),
            title: const Text('通常お送り終了時刻'),
            trailing: Text(
              _formatTime(_dropoffEnd),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.secondary,
              ),
            ),
            onTap: () => _pickTime(
              initial: _dropoffEnd,
              onSelected: (t) => _dropoffEnd = t,
              helpText: 'お送り終了時刻',
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          TextFormField(
            controller: _maxStudentsCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '1日の最大利用者数',
              prefixIcon: Icon(Icons.people),
              suffixText: '名',
            ),
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null || n < 1 || n > 100) return '1〜100名';
              return null;
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: AppElevatedButton.icon(
              onPressed: _saveOperatingHours,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('運営時間を保存'),
            ),
          ),
        ],
      ),
    );
  }

  // ── セクション: LINE応募の受付時間（Day 14）──────────────────

  Widget _buildSlotTtlSection() {
    return _SectionCard(
      title: 'LINE応募の受付時間',
      icon: Icons.timer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '空き枠のLINE通知を送ってから、何時間で応募を締め切るかを設定します。'
            '変更は次回以降の通知から有効で、送信済みの枠の期限は変わりません。',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                key: const Key('slotTtlMinus'),
                icon: const Icon(Icons.remove_circle_outline),
                tooltip: '1時間短くする',
                onPressed: _slotTtlHours > AppSettings.minSlotTtlHours
                    ? () => _saveSlotTtl(_slotTtlHours - 1)
                    : null,
              ),
              Text(
                '$_slotTtlHours 時間',
                key: const Key('slotTtlValue'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              IconButton(
                key: const Key('slotTtlPlus'),
                icon: const Icon(Icons.add_circle_outline),
                tooltip: '1時間長くする',
                onPressed: _slotTtlHours < AppSettings.maxSlotTtlHours
                    ? () => _saveSlotTtl(_slotTtlHours + 1)
                    : null,
              ),
              const SizedBox(width: 8),
              const Text(
                '（${AppSettings.minSlotTtlHours}〜${AppSettings.maxSlotTtlHours}時間）',
                style:
                    TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── セクション: 管理者 LINE userId（Day 15）──────────────────

  Widget _buildAdminLineUserIdSection() {
    return _SectionCard(
      title: '管理者のLINE通知',
      icon: Icons.notifications_active_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '保護者がLINEで空き枠に応募（確定）または取り消したとき、'
            'ここに設定したLINEへ1通だけ通知します。'
            '事業所代表者が自分のLINEで公式アカウントを友だち追加・連携し、'
            'その userId を貼り付けてください。空欄で保存すると通知を止めます。',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('adminLineUserIdField'),
            controller: _adminLineUserIdCtrl,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '管理者 LINE userId',
              hintText: 'U1234567890abcdef1234567890abcdef',
              prefixIcon: const Icon(Icons.badge_outlined),
              errorText: _adminLineUserIdError,
            ),
            onChanged: (_) {
              if (_adminLineUserIdError != null) {
                setState(() => _adminLineUserIdError = null);
              }
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: AppElevatedButton.icon(
              key: const Key('adminLineUserIdSave'),
              onPressed: _saveAdminLineUserId,
              icon: const Icon(Icons.save),
              label: const Text('管理者 userId を保存'),
            ),
          ),
        ],
      ),
    );
  }

  // ── セクション: Google Maps API（2キー方式）────────────────

  Widget _buildApiKeySection() {
    return _SectionCard(
      title: 'Google Maps API',
      icon: Icons.map,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildApiKeyHelpBanner(),
          const SizedBox(height: 16),
          _buildKeySubHeader(
            icon: Icons.vpn_key,
            color: AppColors.primary,
            title: 'Google Maps API キー',
            subtitle: '地図表示・ジオコーディング・ルート計算すべてに利用 — HTTPリファラー制限 OK',
            status: _jsApiKeyStatus,
            loading: _apiKeyLoading,
            failed: _apiKeyLoadError != null,
          ),
          const SizedBox(height: 8),
          SkeletonGate(
            loading: _apiKeyLoading,
            fillParent: false,
            errorMessage: _apiKeyLoadError,
            onRetry: _retryLoadSettings,
            skeleton: const SettingsSkeleton(),
            builder: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _jsApiKeyCtrl,
                  obscureText: !_jsApiKeyVisible,
                  decoration: InputDecoration(
                    labelText: 'API キー (AIza...)',
                    prefixIcon: const Icon(Icons.vpn_key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _jsApiKeyVisible
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _jsApiKeyVisible = !_jsApiKeyVisible),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Maps JavaScript API キーを入力してください。\n'
                  '地図表示・住所検索・ルート計算すべてに使用されます。\n'
                  '「HTTPリファラー」制限を付けてください。',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceVariant,
                      height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppElevatedButton.icon(
                key: const Key('apiKeySaveButton'),
                onPressed: _apiKeyReady ? _saveJsApiKey : null,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              AppOutlinedButton.icon(
                key: const Key('apiKeyTestButton'),
                onPressed:
                    (_testingJsKey || !_apiKeyReady) ? null : _testJsApiKey,
                icon: _testingJsKey
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: AppSpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 16),
                label: Text(_testingJsKey ? 'テスト中...' : 'テスト'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              TextButton.icon(
                key: const Key('apiKeyClearButton'),
                onPressed: _apiKeyReady ? _clearJsApiKey : null,
                // 無効時は赤のままにせず、ボタン既定の無効色に任せる
                icon: Icon(Icons.delete_outline,
                    size: 16, color: _apiKeyReady ? AppColors.error : null),
                label: Text('クリア',
                    style: _apiKeyReady
                        ? const TextStyle(color: AppColors.error)
                        : null),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Google Cloud Console で有効にする API:\n'
            '• Maps JavaScript API\n'
            '• Geocoding API\n'
            '• Directions API',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceVariant,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyHelpBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.help_outline, size: 18, color: AppColors.info),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'JavaScript API 経由に統一しました。\n'
              'JSキー（1つ）で地図表示・住所検索・ルート計算すべてが動作します。\n'
              'CORSエラーなし、キーがURLに露出しない安全な構成です。',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.info,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// キーのサブヘッダー（アイコン・タイトル・状態バッジ）
  Widget _buildKeySubHeader({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required ApiKeyStatus status,
    bool loading = false,
    bool failed = false,
  }) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _ApiKeyStatusBadge(status: status, loading: loading, failed: failed),
      ],
    );
  }

  // ── セクション: アプリ情報 ────────────────────────────────────

  Widget _buildAppInfoSection() {
    return const _SectionCard(
      title: 'アプリ情報',
      icon: Icons.info_outline,
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tag, size: 20),
            title: Text('バージョン'),
            // pubspec.yaml の version（ビルド時に作られる version.json から読む。手で書かない）
            trailing: _AppVersionText(),
          ),
          Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.storage, size: 20),
            title: Text('データストレージ'),
            // 業務データは Firestore（事業所で共有。ステップ1で移行）
            trailing: Text('Firestore（事業所で共有）',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.code, size: 20),
            title: Text('フレームワーク'),
            // ビルドに使った Flutter の版（flutter build / run が自動で埋める。手で書かない）
            trailing: Text(frameworkVersionLabel,
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// _SectionCard
// ════════════════════════════════════════════════════════════════
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurface,
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// _ApiKeyStatusBadge
// ════════════════════════════════════════════════════════════════
class _ApiKeyStatusBadge extends StatelessWidget {
  final ApiKeyStatus status;

  /// 読込中 / 読込失敗は「未設定」と区別して表示する
  final bool loading;
  final bool failed;
  const _ApiKeyStatusBadge({
    required this.status,
    this.loading = false,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    late Color color;
    late IconData icon;
    late String label;

    if (failed) {
      return _buildBadge(AppColors.error, Icons.error_outline, '読込失敗');
    }
    if (loading) {
      return _buildBadge(
          AppColors.onSurfaceVariant, Icons.hourglass_empty, '読込中');
    }

    switch (status) {
      case ApiKeyStatus.valid:
        color = AppColors.success;
        icon = Icons.check_circle;
        label = '設定済み（有効）';
        break;
      case ApiKeyStatus.invalid:
        color = AppColors.error;
        icon = Icons.cancel;
        label = '無効なAPIキー';
        break;
      case ApiKeyStatus.notSet:
        color = AppColors.warning;
        icon = Icons.warning_amber;
        label = '未設定';
        break;
    }

    return _buildBadge(color, icon, label);
  }

  Widget _buildBadge(Color color, IconData icon, String label) {
    return Container(
      key: const Key('apiKeyStatusBadge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Text(
            'APIキー: $label',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// アプリの版（pubspec.yaml の version）。読めないときは「（不明）」
class _AppVersionText extends StatelessWidget {
  const _AppVersionText();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: AppVersion.load(),
      builder: (context, snap) => Text(
        snap.connectionState == ConnectionState.done
            ? (snap.data ?? '（不明）')
            : '…',
        key: const Key('appVersionText'),
        style: const TextStyle(color: AppColors.onSurfaceVariant),
      ),
    );
  }
}
