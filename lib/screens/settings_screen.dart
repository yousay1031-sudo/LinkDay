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
  final _apiKeyCtrl = TextEditingController();
  final _maxStudentsCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // ── 状態 ─────────────────────────────────────────────────────
  bool _apiKeyVisible = false;
  ApiKeyStatus _apiKeyStatus = ApiKeyStatus.notSet;
  bool _testingApiKey = false;
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
    _apiKeyCtrl.dispose();
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
    final apiKey = await SettingsService.instance.loadApiKey();

    setState(() {
      _facilityNameCtrl.text = settings.facilityName;
      _facilityAddressCtrl.text = settings.facilityAddress;
      _maxStudentsCtrl.text = settings.maxStudentsPerDay.toString();
      _apiKeyCtrl.text = apiKey ?? '';
      _apiKeyStatus =
          (apiKey != null && apiKey.isNotEmpty) ? ApiKeyStatus.valid : ApiKeyStatus.notSet;
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

  Future<void> _saveApiKey() async {
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('APIキーを入力してください', AppColors.error);
      return;
    }
    await SettingsService.instance.saveApiKey(key);
    if (!mounted) return;
    setState(() => _apiKeyStatus = ApiKeyStatus.valid);
    _showSnack('APIキーを保存しました', AppColors.success);
  }

  Future<void> _testApiKey() async {
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) {
      _showSnack('APIキーを入力してください', AppColors.error);
      return;
    }
    setState(() => _testingApiKey = true);
    try {
      final status = await SettingsService.instance.testApiKey(key);
      if (!mounted) return;
      setState(() => _apiKeyStatus = status);
      switch (status) {
        case ApiKeyStatus.valid:
          _showSnack('✅ APIキーは有効です', AppColors.success);
          break;
        case ApiKeyStatus.invalid:
          _showSnack('❌ APIキーが無効か権限不足です', AppColors.error);
          break;
        case ApiKeyStatus.notSet:
          _showSnack('⚠️ APIキーが未設定です', AppColors.warning);
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _apiKeyStatus = ApiKeyStatus.invalid);
      _showSnack('テスト失敗: $e', AppColors.error);
    } finally {
      if (mounted) setState(() => _testingApiKey = false);
    }
  }

  Future<void> _clearApiKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('APIキーをクリア'),
        content: const Text('保存済みのAPIキーを削除しますか？'),
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
    if (confirmed != true || !mounted) return;
    await SettingsService.instance.clearApiKey();
    if (!mounted) return;
    setState(() {
      _apiKeyCtrl.clear();
      _apiKeyStatus = ApiKeyStatus.notSet;
    });
    _showSnack('APIキーを削除しました', AppColors.warning);
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

  // ── セクション: Google Maps API ──────────────────────────────

  Widget _buildApiKeySection() {
    return _SectionCard(
      title: 'Google Maps API',
      icon: Icons.map,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // APIキー状態表示
          _ApiKeyStatusBadge(status: _apiKeyStatus),
          const SizedBox(height: 12),
          // APIキー入力欄
          TextFormField(
            controller: _apiKeyCtrl,
            obscureText: !_apiKeyVisible,
            decoration: InputDecoration(
              labelText: 'Google Maps APIキー',
              prefixIcon: const Icon(Icons.key),
              suffixIcon: IconButton(
                icon: Icon(_apiKeyVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () =>
                    setState(() => _apiKeyVisible = !_apiKeyVisible),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '※ APIキーはデバイスのローカルストレージに保存されます',
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // ボタン群
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _saveApiKey,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('保存'),
              ),
              OutlinedButton.icon(
                onPressed: _testingApiKey ? null : _testApiKey,
                icon: _testingApiKey
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 18),
                label: Text(_testingApiKey ? 'テスト中...' : 'テスト'),
              ),
              TextButton.icon(
                onPressed: _clearApiKey,
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: AppColors.error),
                label: const Text(
                  'クリア',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(),
          const Text(
            '必要な API:\n'
            '• Geocoding API（住所→座標変換）\n'
            '• Directions API（ルート計算）\n'
            '• Distance Matrix API（距離行列）\n'
            '• Maps JavaScript API（地図表示）',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
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
