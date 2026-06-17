import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final _jsApiKeyCtrl = TextEditingController();
  final _restApiKeyCtrl = TextEditingController();
  final _maxStudentsCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // ── 状態 ─────────────────────────────────────────────────────
  bool _jsApiKeyVisible = false;
  bool _restApiKeyVisible = false;
  ApiKeyStatus _jsApiKeyStatus = ApiKeyStatus.notSet;
  ApiKeyStatus _restApiKeyStatus = ApiKeyStatus.notSet;
  bool _testingJsKey = false;
  bool _testingRestKey = false;
  bool _geocoding = false;
  int _vehicleCount = 2;
  final List<TextEditingController> _vehicleNameCtrls = [];
  final List<TextEditingController> _vehicleCapCtrls = [];
  TimeOfDay _pickupStart = const TimeOfDay(hour: 8, minute: 30);
  TimeOfDay _dropoffEnd = const TimeOfDay(hour: 16, minute: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
  }

  @override
  void dispose() {
    _facilityNameCtrl.dispose();
    _facilityAddressCtrl.dispose();
    _jsApiKeyCtrl.dispose();
    _restApiKeyCtrl.dispose();
    _maxStudentsCtrl.dispose();
    for (final c in _vehicleNameCtrls) {
      c.dispose();
    }
    for (final c in _vehicleCapCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = SettingsService.instance.getSettings();
    final jsKey = await SettingsService.instance.loadJsApiKey();
    final restKey = await SettingsService.instance.loadRestApiKey();

    setState(() {
      _facilityNameCtrl.text = settings.facilityName;
      _facilityAddressCtrl.text = settings.facilityAddress;
      _maxStudentsCtrl.text = settings.maxStudentsPerDay.toString();
      _jsApiKeyCtrl.text = jsKey ?? '';
      _restApiKeyCtrl.text = restKey ?? '';
      _jsApiKeyStatus =
          (jsKey != null && jsKey.isNotEmpty) ? ApiKeyStatus.valid : ApiKeyStatus.notSet;
      _restApiKeyStatus =
          (restKey != null && restKey.isNotEmpty) ? ApiKeyStatus.valid : ApiKeyStatus.notSet;
      _vehicleCount = settings.vehicleCount;
      _pickupStart = _parseTime(settings.defaultPickupStart);
      _dropoffEnd = _parseTime(settings.defaultDropoffEnd);
      _rebuildVehicleControllers(settings.vehicleNames, settings.vehicleCapacities);
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
    if (!_formKey.currentState!.validate()) return;
    await SettingsService.instance.updateFacility(
      _facilityNameCtrl.text.trim(),
      _facilityAddressCtrl.text.trim(),
    );
    if (!mounted) return;
    _showSnack('事業所情報を保存しました', AppColors.success);
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

  // ── JS API キー操作 ─────────────────────────────────────────

  Future<void> _saveJsApiKey() async {
    final key = _jsApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('Maps JavaScript API キーを入力してください', AppColors.error);
      return;
    }
    await SettingsService.instance.saveJsApiKey(key);
    if (!mounted) return;
    setState(() => _jsApiKeyStatus = ApiKeyStatus.valid);
    _showSnack('JS API キーを保存しました', AppColors.success);
  }

  Future<void> _testJsApiKey() async {
    final key = _jsApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('Maps JavaScript API キーを入力してください', AppColors.error);
      return;
    }
    setState(() => _testingJsKey = true);
    try {
      final status = await SettingsService.instance.testJsApiKey(key);
      if (!mounted) return;
      setState(() => _jsApiKeyStatus = status);
      switch (status) {
        case ApiKeyStatus.valid:
          _showSnack('✅ JS API キーの形式は正しいです', AppColors.success);
          break;
        case ApiKeyStatus.invalid:
          _showSnack('❌ JS API キーの形式が不正です（AIza で始まる文字列を確認）', AppColors.error);
          break;
        case ApiKeyStatus.notSet:
          _showSnack('⚠️ JS API キーが未設定です', AppColors.warning);
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
    final confirmed = await _confirmClear('JS API キー（地図表示用）');
    if (confirmed != true || !mounted) return;
    await SettingsService.instance.clearJsApiKey();
    if (!mounted) return;
    setState(() {
      _jsApiKeyCtrl.clear();
      _jsApiKeyStatus = ApiKeyStatus.notSet;
    });
    _showSnack('JS API キーを削除しました', AppColors.warning);
  }

  // ── REST API キー操作 ────────────────────────────────────────

  Future<void> _saveRestApiKey() async {
    final key = _restApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('REST API キーを入力してください', AppColors.error);
      return;
    }
    await SettingsService.instance.saveRestApiKey(key);
    if (!mounted) return;
    setState(() => _restApiKeyStatus = ApiKeyStatus.valid);
    _showSnack('REST API キーを保存しました', AppColors.success);
  }

  Future<void> _testRestApiKey() async {
    final key = _restApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('REST API キーを入力してください', AppColors.error);
      return;
    }
    setState(() => _testingRestKey = true);
    try {
      final status = await SettingsService.instance.testRestApiKey(key);
      if (!mounted) return;
      setState(() => _restApiKeyStatus = status);
      switch (status) {
        case ApiKeyStatus.valid:
          _showSnack('✅ REST API キーは有効です（Geocoding 成功）', AppColors.success);
          break;
        case ApiKeyStatus.invalid:
          _showSnack('❌ REST API キーが無効 / 権限不足 / リファラー制限の可能性があります', AppColors.error);
          break;
        case ApiKeyStatus.notSet:
          _showSnack('⚠️ REST API キーが未設定です', AppColors.warning);
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _restApiKeyStatus = ApiKeyStatus.invalid);
      _showSnack('テスト失敗: $e', AppColors.error);
    } finally {
      if (mounted) setState(() => _testingRestKey = false);
    }
  }

  Future<void> _clearRestApiKey() async {
    final confirmed = await _confirmClear('REST API キー（ルート計算用）');
    if (confirmed != true || !mounted) return;
    await SettingsService.instance.clearRestApiKey();
    if (!mounted) return;
    setState(() {
      _restApiKeyCtrl.clear();
      _restApiKeyStatus = ApiKeyStatus.notSet;
    });
    _showSnack('REST API キーを削除しました', AppColors.warning);
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
      final result = await SettingsService.instance.geocodeFacility();
      if (!mounted) return;
      _showSnack(
        '緯度経度を取得しました: ${result.lat.toStringAsFixed(5)}, ${result.lng.toStringAsFixed(5)}',
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
        child: child!,
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
    final settings = SettingsService.instance.getSettings();
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
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? '住所は必須です' : null,
          ),
          const SizedBox(height: 8),
          // Geocoding 結果表示
          if (settings.hasGeocode)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.my_location, size: 16, color: AppColors.success),
                  const SizedBox(width: 6),
                  Text(
                    '座標: ${settings.geocodeLabel}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _geocoding ? null : _geocodeFacility,
                  icon: _geocoding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.gps_fixed, size: 18),
                  label: Text(_geocoding ? '取得中...' : '住所から座標を取得'),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saveFacility,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
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
          ...List.generate(_vehicleCount, (i) {
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
          // ── ヘルプバナー ───────────────────────────────────────
          _buildApiKeyHelpBanner(),
          const SizedBox(height: 16),

          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          // キー① Maps JavaScript API（地図表示用）
          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          _buildKeySubHeader(
            icon: Icons.language,
            color: AppColors.secondary,
            title: 'Maps JavaScript API キー',
            subtitle: '地図表示用 — HTTPリファラー制限 OK',
            status: _jsApiKeyStatus,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _jsApiKeyCtrl,
            obscureText: !_jsApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'JS API キー (AIza...)',
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
            'Google Cloud Console → APIとサービス → 認証情報\n'
            '「HTTPリファラー」制限を付けて安全に使用できます',
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
                  backgroundColor: AppColors.secondary,
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
                    : const Icon(Icons.check_circle_outline, size: 16),
                label: Text(_testingJsKey ? 'チェック中...' : 'チェック'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.secondary,
                  side: const BorderSide(color: AppColors.secondary),
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

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          // キー② REST API（Geocoding / Directions / DistanceMatrix）
          // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          _buildKeySubHeader(
            icon: Icons.route,
            color: AppColors.primary,
            title: 'REST API キー',
            subtitle: 'ルート計算用 — リファラー制限を付けないこと',
            status: _restApiKeyStatus,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _restApiKeyCtrl,
            obscureText: !_restApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'REST API キー (AIza...)',
              prefixIcon: const Icon(Icons.vpn_key),
              suffixIcon: IconButton(
                icon: Icon(
                  _restApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _restApiKeyVisible = !_restApiKeyVisible),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // 警告: REST キーにリファラー制限を付けないよう注意
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber, size: 14, color: AppColors.warning),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'このキーには「HTTPリファラー」制限を付けないでください。\n'
                    'IPアドレス制限または予算アラートで保護してください。',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.warning,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _saveRestApiKey,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _testingRestKey ? null : _testRestApiKey,
                icon: _testingRestKey
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 16),
                label: Text(_testingRestKey ? 'テスト中...' : 'テスト'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
              ),
              TextButton.icon(
                onPressed: _clearRestApiKey,
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

          // 必要 API リスト
          const Text(
            '有効にすべき Google Cloud API:\n'
            '• Maps JavaScript API（JS キー）\n'
            '• Geocoding API（REST キー）\n'
            '• Directions API（REST キー）\n'
            '• Distance Matrix API（REST キー）',
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

  /// なぜ2つのキーが必要かのヘルプバナー
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
              'Google の仕様により、地図表示用と REST API 用でキーを分ける必要があります。\n'
              'JS用はHTTPリファラー制限で安全に。REST用はIP制限または予算アラートで保護してください。',
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
