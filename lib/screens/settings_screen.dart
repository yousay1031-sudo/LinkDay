import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_settings.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

// ════════════════════════════════════════════════════════════════
// SettingsScreen
// ════════════════════════════════════════════════════════════════
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ── コントローラー ────────────────────────────────────────────
  final _facilityNameCtrl = TextEditingController();
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

  // ── 地図プレビュー状態 ─────────────────────────────────────────
  /// geocode 後に表示する事業所座標（マーカー位置・地図中心）
  double? _previewLat;
  double? _previewLng;
  /// 地図コントローラー
  GoogleMapController? _mapController;
  /// 現在のマーカー位置（ドラッグ後に更新）
  LatLng? _markerLatLng;
  bool _savingPosition = false;

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
  }

  /// 同期取得できる設定値をコントローラ・状態に反映する（setState なし）
  void _applySettingsSync(AppSettings settings) {
    _facilityNameCtrl.text = settings.facilityName;
    _facilityAddressCtrl.text = settings.facilityAddress;
    _maxStudentsCtrl.text = settings.maxStudentsPerDay.toString();
    _vehicleCount = settings.vehicleCount.clamp(1, 5);
    _pickupStart = _parseTime(settings.defaultPickupStart);
    _dropoffEnd = _parseTime(settings.defaultDropoffEnd);
    _rebuildVehicleControllers(settings.vehicleNames, settings.vehicleCapacities);

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
    _facilityNameCtrl.dispose();
    _facilityAddressCtrl.dispose();
    _jsApiKeyCtrl.dispose();
    _maxStudentsCtrl.dispose();
    for (final c in _vehicleNameCtrls) {
      c.dispose();
    }
    for (final c in _vehicleCapCtrls) {
      c.dispose();
    }
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = SettingsService.instance.getSettings();
    final jsKey = await SettingsService.instance.loadJsApiKey();
    if (!mounted) return;

    debugPrint('[SettingsScreen] _loadSettings: apiKey=${jsKey == null || jsKey.isEmpty ? "未設定" : "設定済み"}, '
        'facilityLatLng=${settings.hasGeocode ? "あり" : "未設定"}, '
        'vehicleCount=${settings.vehicleCount}');

    setState(() {
      _applySettingsSync(settings);
      _jsApiKeyCtrl.text = jsKey ?? '';
      _jsApiKeyStatus =
          (jsKey != null && jsKey.isNotEmpty) ? ApiKeyStatus.valid : ApiKeyStatus.notSet;
    });
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

    await SettingsService.instance.updateFacility(
      _facilityNameCtrl.text.trim(),
      newAddress,
    );
    if (!mounted) return;
    _showSnack('事業所情報を保存しました', AppColors.success);

    // 住所が変更された場合は自動でジオコーディングを実行
    if (addressChanged && newAddress.isNotEmpty) {
      final jsKey = _jsApiKeyCtrl.text.trim();
      if (jsKey.isNotEmpty) {
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
    final caps = _vehicleCapCtrls
        .map((c) => int.tryParse(c.text) ?? 5)
        .toList();
    await SettingsService.instance.updateVehicles(_vehicleCount, names, caps);
    if (!mounted) return;
    _showSnack('車両設定を保存しました', AppColors.success);
  }

  Future<void> _saveOperatingHours() async {
    final maxStudents = int.tryParse(_maxStudentsCtrl.text) ?? 10;
    await SettingsService.instance.updateOperatingHours(
      _formatTime(_pickupStart),
      _formatTime(_dropoffEnd),
      maxStudents,
    );
    if (!mounted) return;
    _showSnack('運営時間を保存しました', AppColors.success);
  }

  // ── API キー操作（1キー方式） ─────────────────────────────

  Future<void> _saveJsApiKey() async {
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
          _showSnack('✅ API キー有効（地図表示・ルート計算・ジオコーディングが動作します）', AppColors.success);
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

      // 地図が既に起動済みの場合はカメラを移動
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(latLng, 16),
      );

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildFacilitySection(),
              const SizedBox(height: 16),
              _buildVehicleSection(),
              const SizedBox(height: 16),
              _buildOperatingHoursSection(),
              const SizedBox(height: 16),
              _buildApiKeySection(),
              const SizedBox(height: 16),
              _buildAppInfoSection(),
              const SizedBox(height: 32),
            ],
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
              OutlinedButton.icon(
                onPressed: _geocoding ? null : _geocodeFacility,
                icon: _geocoding
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.gps_fixed, size: 16),
                label: Text(_geocoding ? '取得中...' : '座標を取得',
                    style: const TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _openInGoogleMaps,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('G-Mapsで確認',
                    style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.info,
                  side: const BorderSide(color: AppColors.info),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _saveFacility,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 座標表示ヘッダー
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              topRight: Radius.circular(10),
            ),
            border: Border.all(
                color: AppColors.success.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.my_location, size: 16,
                  color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '緯度: ${marker.latitude.toStringAsFixed(7)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.onSurface,
                          fontFamily: 'monospace'),
                    ),
                    Text(
                      '経度: ${marker.longitude.toStringAsFixed(7)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.onSurface,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'マーカーをドラッグして\n位置を微調整できます',
                style: TextStyle(
                    fontSize: 11, color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.right,
              ),
            ],
          ),
        ),
        // Google マップ
        ClipRRect(
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(10),
            bottomRight: Radius.circular(10),
          ),
          child: SizedBox(
            height: 260,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: center,
                zoom: 16,
              ),
              markers: {
                Marker(
                  markerId: const MarkerId('facility_preview'),
                  position: marker,
                  draggable: true,
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueOrange),
                  infoWindow: InfoWindow(
                    title: _facilityNameCtrl.text.isNotEmpty
                        ? _facilityNameCtrl.text
                        : '事業所',
                    snippet: _facilityAddressCtrl.text.trim(),
                  ),
                  onDragEnd: _onMarkerDragged,
                ),
              },
              onMapCreated: (controller) {
                _mapController = controller;
              },
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
              mapToolbarEnabled: false,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 「この位置を事業所に設定」ボタン
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _savingPosition ? null : _saveMarkerPosition,
            icon: _savingPosition
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.place, size: 18),
            label: Text(
              _savingPosition ? '保存中...' : 'この位置を事業所に設定',
              style: const TextStyle(fontSize: 14),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ],
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
            child: ElevatedButton.icon(
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
            child: ElevatedButton.icon(
              onPressed: _saveOperatingHours,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('運営時間を保存'),
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
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _jsApiKeyCtrl,
            obscureText: !_jsApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'API キー (AIza...)',
              prefixIcon: const Icon(Icons.vpn_key_outlined),
              suffixIcon: IconButton(
                icon: Icon(
                  _jsApiKeyVisible ? Icons.visibility_off : Icons.visibility,
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
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _saveJsApiKey,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _testingJsKey ? null : _testJsApiKey,
                icon: _testingJsKey
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 16),
                label: Text(_testingJsKey ? 'テスト中...' : 'テスト'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              TextButton.icon(
                onPressed: _clearJsApiKey,
                icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.error),
                label: const Text('クリア', style: TextStyle(color: AppColors.error)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
        _ApiKeyStatusBadge(status: status),
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
            trailing: Text('1.0.0+6',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.storage, size: 20),
            title: Text('データストレージ'),
            trailing: Text('Hive (IndexedDB)',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.code, size: 20),
            title: Text('フレームワーク'),
            trailing: Text('Flutter 3.35.4',
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
  const _ApiKeyStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late Color color;
    late IconData icon;
    late String label;

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

    return Container(
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
