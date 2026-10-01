import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/customer.dart';
import '../services/customer_service.dart';
import '../services/maps_js_service.dart';
import '../services/settings_service.dart';
import '../services/transport_location_resolver.dart';
import '../theme/app_theme.dart';
import '../utils/kana_util.dart';
import '../widgets/geocode_candidate_sheet.dart';

class CustomerEditScreen extends StatefulWidget {
  final Customer? customer;

  const CustomerEditScreen({super.key, this.customer});

  @override
  State<CustomerEditScreen> createState() => _CustomerEditScreenState();
}

class _CustomerEditScreenState extends State<CustomerEditScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool get _isEditing => widget.customer != null;

  // ── Day 8: 送迎場所 座標バッファ（保存時に Customer に反映）──
  // index 0..2 = 送迎場所1〜3。テキストが変更されたら該当 slot を未解決に戻す。
  final List<double?> _locLats = [null, null, null];
  final List<double?> _locLngs = [null, null, null];
  final List<String> _locStatus = [
    Customer.locUnresolved,
    Customer.locUnresolved,
    Customer.locUnresolved,
  ];
  final List<String> _locOriginalText = ['', '', ''];
  final List<bool> _locBusy = [false, false, false];
  // Day 8 修正: 採用根拠（formattedAddress / types）。誤採用検出に使う。
  final List<String?> _locFormatted = [null, null, null];
  final List<String?> _locTypes = [null, null, null];

  // ── コントローラー ──────────────────────────────────────────────────
  late final TextEditingController _nameCtrl;
  late final TextEditingController _nameKanaCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _lineUserIdCtrl;
  late final TextEditingController _guardianNameCtrl;
  late final TextEditingController _guardianPhoneCtrl;
  late final TextEditingController _recipientCertNumberCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _transport1Ctrl;
  late final TextEditingController _transport2Ctrl;
  late final TextEditingController _transport3Ctrl;

  // ── 状態 ───────────────────────────────────────────────────────────
  DateTime? _birthday;
  DateTime? _certExpiry;
  String? _gender;
  int _monthlyAvailableDays = 23;
  int _currentMonthUsedDays = 0;
  List<int> _regularDays = [];

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _nameKanaCtrl = TextEditingController(text: c?.nameKana ?? '');
    _phoneCtrl = TextEditingController(text: c?.phone ?? '');
    _lineUserIdCtrl = TextEditingController(text: c?.lineUserId ?? '');
    _guardianNameCtrl = TextEditingController(text: c?.guardianName ?? '');
    _guardianPhoneCtrl = TextEditingController(text: c?.guardianPhone ?? '');
    _recipientCertNumberCtrl =
        TextEditingController(text: c?.recipientCertNumber ?? '');
    _notesCtrl = TextEditingController(text: c?.notes ?? '');
    _transport1Ctrl = TextEditingController(
        text: c != null && c.transportLocations.isNotEmpty
            ? c.transportLocations[0]
            : '');
    _transport2Ctrl = TextEditingController(
        text: c != null && c.transportLocations.length > 1
            ? c.transportLocations[1]
            : '');
    _transport3Ctrl = TextEditingController(
        text: c != null && c.transportLocations.length > 2
            ? c.transportLocations[2]
            : '');

    // Day 8: 採用済み座標を読み込み
    if (c != null) {
      for (int i = 0; i < 3 && i < c.transportLocations.length; i++) {
        final coord = c.transportCoord(i);
        _locLats[i] = coord?.lat;
        _locLngs[i] = coord?.lng;
        _locStatus[i] = c.transportStatus(i);
        _locFormatted[i] = c.transportFormatted(i);
        final t = c.transportTypes(i);
        _locTypes[i] = t.isEmpty ? null : t.join(',');
        _locOriginalText[i] = c.transportLocations[i];
      }
    }
    // テキスト変更 → 座標を無効化（別の場所になるため）
    for (int i = 0; i < 3; i++) {
      _transportCtrl(i).addListener(() => _onLocationTextChanged(i));
    }
    _birthday = c?.birthday;
    _certExpiry = c?.recipientCertExpiry;
    _gender = c?.gender;
    _monthlyAvailableDays = c?.monthlyAvailableDays ?? 23;
    _currentMonthUsedDays = c?.currentMonthUsedDays ?? 0;
    _regularDays = List.from(c?.regularDays ?? []);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameKanaCtrl.dispose();
    _phoneCtrl.dispose();
    _lineUserIdCtrl.dispose();
    _guardianNameCtrl.dispose();
    _guardianPhoneCtrl.dispose();
    _recipientCertNumberCtrl.dispose();
    _notesCtrl.dispose();
    _transport1Ctrl.dispose();
    _transport2Ctrl.dispose();
    _transport3Ctrl.dispose();
    super.dispose();
  }

  // ── ふりがなカナ変換 ─────────────────────────────────────────────

  void _convertKana() {
    final converted = KanaUtil.normalizeKana(_nameKanaCtrl.text);
    setState(() {
      _nameKanaCtrl.text = converted;
      _nameKanaCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: converted.length),
      );
    });
  }

  // ── 日付ピッカー ────────────────────────────────────────────────────

  Future<void> _pickBirthday() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(2015, 4, 1),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      helpText: '生年月日を選択',
      locale: const Locale('ja', 'JP'),
    );
    if (picked != null && mounted) {
      setState(() => _birthday = picked);
    }
  }

  Future<void> _pickCertExpiry() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _certExpiry ?? DateTime.now().add(const Duration(days: 180)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030, 12, 31),
      helpText: '受給者証有効期限を選択',
      locale: const Locale('ja', 'JP'),
    );
    if (picked != null && mounted) {
      setState(() => _certExpiry = picked);
    }
  }

  // ── Day 8: 送迎場所 座標操作 ───────────────────────────────────────

  TextEditingController _transportCtrl(int i) => switch (i) {
        0 => _transport1Ctrl,
        1 => _transport2Ctrl,
        _ => _transport3Ctrl,
      };

  void _onLocationTextChanged(int i) {
    if (!mounted) return;
    final now = _transportCtrl(i).text.trim();
    setState(() {
      if (now != _locOriginalText[i] && _locStatus[i] != Customer.locUnresolved) {
        // 別の場所に書き換えられた → 座標を無効化
        _locLats[i] = null;
        _locLngs[i] = null;
        _locStatus[i] = Customer.locUnresolved;
        _locFormatted[i] = null;
        _locTypes[i] = null;
      } else if (now == _locOriginalText[i] && widget.customer != null) {
        // 元に戻した → 元の座標を復元
        final coord = widget.customer!.transportCoord(i);
        if (coord != null && _locLats[i] == null) {
          _locLats[i] = coord.lat;
          _locLngs[i] = coord.lng;
          _locStatus[i] = widget.customer!.transportStatus(i);
          _locFormatted[i] = widget.customer!.transportFormatted(i);
          final t = widget.customer!.transportTypes(i);
          _locTypes[i] = t.isEmpty ? null : t.join(',');
        }
      }
      // それ以外も再 build（チップ行の表示/非表示切替のため）
    });
  }

  ({double lat, double lng})? _locCoord(int i) {
    final lat = _locLats[i];
    final lng = _locLngs[i];
    return (lat != null && lng != null) ? (lat: lat, lng: lng) : null;
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  /// 「候補を取得」
  Future<void> _fetchCandidates(int i) async {
    final address = _transportCtrl(i).text.trim();
    if (!TransportLocationResolver.isResolvable(address)) {
      _snack('送迎場所${i + 1} が未入力です', AppColors.warning);
      return;
    }
    setState(() => _locBusy[i] = true);
    try {
      // Day 8 修正2: 短名クエリの自動補完（表示文字列は変更しない）
      final query = TransportLocationResolver.buildGeocodeQuery(address);
      if (query != address) {
        debugPrint('[CustomerEdit] query augment: "$address" → "$query"');
      }
      final result = await MapsJsService.instance.geocodeCandidates(query);
      if (!mounted) return;
      if (result.isEmpty) {
        setState(() {
          _locLats[i] = null;
          _locLngs[i] = null;
          _locStatus[i] = Customer.locFailed;
          _locFormatted[i] = null;
          _locTypes[i] = null;
        });
        _snack('「$address」に該当する地点が見つかりませんでした', AppColors.error);
        return;
      }
      // Day 8 修正1: 1 件ヒットでも帯広市外・粒度不足・部分一致なら自動採用しない
      final judgement = result.isSingle
          ? TransportLocationResolver.judgeAutoAdopt(result.candidates.first)
          : null;
      final blocked = judgement != null && !judgement.allowed;
      if (blocked) {
        debugPrint('[Resolver] auto-adopt blocked: "$address" → ${judgement.reasonText}');
      }
      final picked = await showGeocodeCandidateSheet(
        context,
        address: address,
        candidates: result.sortedByPreference,
        title: '送迎場所${i + 1} の候補',
        autoAdopted: result.isSingle && !blocked,
        blockReasonText: blocked ? judgement.reasonText : null,
        query: query,
      );
      if (picked == null) {
        // キャンセル: 自動採用可な 1 件のみ保持。ブロック時は未解決のまま。
        if (result.isSingle && !blocked && _locCoord(i) == null) {
          final c = result.candidates.first;
          setState(() {
            _locLats[i] = c.lat;
            _locLngs[i] = c.lng;
            _locStatus[i] = Customer.locResolved;
            _locFormatted[i] = c.formattedAddress;
            _locTypes[i] = c.types.isEmpty ? null : c.types.join(',');
          });
        } else if (blocked) {
          _snack('送迎場所${i + 1}: 自動採用不可（${judgement.reasonText}）。'
              '候補を選んで採用してください。', AppColors.warning);
        }
        return;
      }
      // 受け入れ基準5: 国レベル座標はどの経路でも保存しない
      if (!TransportLocationResolver.isStorableCandidate(picked)) {
        _snack('「${picked.formattedAddress}」は国レベルの座標のため採用できません', AppColors.error);
        return;
      }
      setState(() {
        _locLats[i] = picked.lat;
        _locLngs[i] = picked.lng;
        _locStatus[i] = Customer.locManual;
        _locFormatted[i] = picked.formattedAddress;
        _locTypes[i] = picked.types.isEmpty ? null : picked.types.join(',');
      });
      _snack('送迎場所${i + 1}: ${picked.formattedAddress} を採用（保存で確定）', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locLats[i] = null;
        _locLngs[i] = null;
        _locStatus[i] = Customer.locFailed;
        _locFormatted[i] = null;
        _locTypes[i] = null;
      });
      _snack('候補取得に失敗: $e', AppColors.error);
    } finally {
      if (mounted) setState(() => _locBusy[i] = false);
    }
  }

  // ── 地図から直接ピン指定（最終手段 / Day 8 追加改修） ──────────

  /// 編集中バッファの座標から初期位置算出用の一時 Customer を組む
  ///
  /// 保存前の編集中状態（_locLats/_locLngs/_locStatus）を反映させるため、
  /// widget.customer ではなくバッファから作る。
  Customer _bufferAsCustomer() {
    final locs = <String>[];
    final lats = <double?>[];
    final lngs = <double?>[];
    final stat = <String>[];
    for (int k = 0; k < 3; k++) {
      // 空欄も index を保つためプレースホルダを入れる（座標の添字整合が重要）
      locs.add(_transportCtrl(k).text.trim());
      lats.add(_locLats[k]);
      lngs.add(_locLngs[k]);
      stat.add(_locStatus[k]);
    }
    return Customer(
      name: _nameCtrl.text.trim().isEmpty ? '（新規）' : _nameCtrl.text.trim(),
      nameKana: 'テンポラリ',
      transportLocations: locs,
      transportLocationLats: lats,
      transportLocationLngs: lngs,
      transportLocationStatus: stat,
    );
  }

  /// geocode 0 件・採用可能な候補なしでも位置を確定できる最終手段
  Future<void> _pickOnMap(int i) async {
    final settings = SettingsService.instance.getSettings();
    final initial = TransportLocationResolver.resolveInitialPinPosition(
      _bufferAsCustomer(), i,
      facilityLat: settings.facilityLat,
      facilityLng: settings.facilityLng,
    );
    final label = _transportCtrl(i).text.trim();
    debugPrint('[CustomerEdit] pickOnMap: [$i] initial=$initial');
    final picked = await showMapPinPickerDialog(
      context,
      initial: initial,
      title: '送迎場所${i + 1}',
      addressLabel: label.isEmpty ? null : label,
      reverseGeocode: (lat, lng) async {
        final r = await MapsJsService.instance.reverseGeocode(lat, lng);
        return r.ok ? r.formattedAddress : null;
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _locLats[i] = picked.lat;
      _locLngs[i] = picked.lng;
      _locStatus[i] = Customer.locManual;
      // 逆ジオコードが「日本」等を返した場合も「手動指定地点」に置き換える
      // （sanitizeCoords による誤破棄を防ぐ）
      _locFormatted[i] =
          TransportLocationResolver.sanitizeManualLabel(picked.formattedAddress);
      _locTypes[i] = TransportLocationResolver.manualPinTypes.join(',');
    });
    _snack(
        '送迎場所${i + 1}: ${_locFormatted[i]} を手動指定（保存で確定）', AppColors.success);
  }

  /// 「地図で微調整」
  Future<void> _adjustOnMap(int i) async {
    final coord = _locCoord(i);
    // 座標がなければ事業所座標（または帯広中心）から開始
    final start = coord != null
        ? LatLng(coord.lat, coord.lng)
        : const LatLng(42.9238, 143.1966);
    final picked = await showAdjustCoordDialog(
      context,
      initial: start,
      title: '送迎場所${i + 1}',
      snippet: _transportCtrl(i).text.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _locLats[i] = picked.latitude;
      _locLngs[i] = picked.longitude;
      _locStatus[i] = Customer.locManual;
      _locFormatted[i] = '地図で指定';
      _locTypes[i] = 'premise';
    });
  }

  void _clearCoord(int i) {
    setState(() {
      _locLats[i] = null;
      _locLngs[i] = null;
      _locStatus[i] = Customer.locUnresolved;
      _locFormatted[i] = null;
      _locTypes[i] = null;
    });
  }

  // ── 保存 ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('入力内容を確認してください'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Day 8: 空欄を詰めつつ座標・ステータスも同じ順序で揃える
      final transportLocations = <String>[];
      final locLats = <double?>[];
      final locLngs = <double?>[];
      final locStatus = <String>[];
      final locFormatted = <String?>[];
      final locTypes = <String?>[];
      for (int i = 0; i < 3; i++) {
        final t = _transportCtrl(i).text.trim();
        if (t.isEmpty) continue;
        transportLocations.add(t);
        locLats.add(_locLats[i]);
        locLngs.add(_locLngs[i]);
        locStatus.add(_locStatus[i]);
        locFormatted.add(_locFormatted[i]);
        locTypes.add(_locTypes[i]);
      }

      if (_isEditing) {
        final updated = Customer(
          id: widget.customer!.id,
          name: _nameCtrl.text.trim(),
          nameKana: KanaUtil.normalizeKana(_nameKanaCtrl.text.trim()),
          birthday: _birthday,
          gender: _gender,
          phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
          lineUserId: _lineUserIdCtrl.text.trim().isEmpty
              ? null
              : _lineUserIdCtrl.text.trim(),
          guardianName: _guardianNameCtrl.text.trim().isEmpty
              ? null
              : _guardianNameCtrl.text.trim(),
          guardianPhone: _guardianPhoneCtrl.text.trim().isEmpty
              ? null
              : _guardianPhoneCtrl.text.trim(),
          recipientCertNumber: _recipientCertNumberCtrl.text.trim().isEmpty
              ? null
              : _recipientCertNumberCtrl.text.trim(),
          recipientCertExpiry: _certExpiry,
          monthlyAvailableDays: _monthlyAvailableDays,
          currentMonthUsedDays: _currentMonthUsedDays,
          regularDays: List.from(_regularDays),
          transportLocations: transportLocations,
          notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          createdAt: widget.customer!.createdAt,
          isActive: widget.customer!.isActive,
          transportLocationLats: locLats,
          transportLocationLngs: locLngs,
          transportLocationStatus: locStatus,
          transportLocationFormatted: locFormatted,
          transportLocationTypes: locTypes,
        );
        await CustomerService.instance.updateCustomer(updated);
      } else {
        final customer = Customer(
          name: _nameCtrl.text.trim(),
          nameKana: KanaUtil.normalizeKana(_nameKanaCtrl.text.trim()),
          birthday: _birthday,
          gender: _gender,
          phone: _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
          lineUserId: _lineUserIdCtrl.text.trim().isEmpty
              ? null
              : _lineUserIdCtrl.text.trim(),
          guardianName: _guardianNameCtrl.text.trim().isEmpty
              ? null
              : _guardianNameCtrl.text.trim(),
          guardianPhone: _guardianPhoneCtrl.text.trim().isEmpty
              ? null
              : _guardianPhoneCtrl.text.trim(),
          recipientCertNumber: _recipientCertNumberCtrl.text.trim().isEmpty
              ? null
              : _recipientCertNumberCtrl.text.trim(),
          recipientCertExpiry: _certExpiry,
          monthlyAvailableDays: _monthlyAvailableDays,
          currentMonthUsedDays: _currentMonthUsedDays,
          regularDays: List.from(_regularDays),
          transportLocations: transportLocations,
          notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          transportLocationLats: locLats,
          transportLocationLngs: locLngs,
          transportLocationStatus: locStatus,
          transportLocationFormatted: locFormatted,
          transportLocationTypes: locTypes,
        );
        await CustomerService.instance.addCustomer(customer);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing ? '顧客情報を保存しました' : '顧客を登録しました'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存に失敗しました: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── 削除 ────────────────────────────────────────────────────────────

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.error, size: 22),
            SizedBox(width: 8),
            Text('在籍終了にしますか？'),
          ],
        ),
        content: Text(
          '「${widget.customer!.name}」を在籍終了にします。\n'
          'データは削除されず、非表示になります。\n\n'
          'この操作は取り消せません。',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('在籍終了にする'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CustomerService.instance.deleteCustomer(widget.customer!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('「${widget.customer!.name}」を在籍終了にしました'),
          backgroundColor: AppColors.warning,
        ),
      );
      Navigator.of(context).pop(true);
    }
  }

  // ── ビルド ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '顧客情報の編集' : '新規登録'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '在籍終了にする',
              color: Colors.white,
              onPressed: _confirmDelete,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 100),
          child: Column(
            children: [
              _buildSection('基本情報', _buildBasicInfo()),
              _buildSection('保護者情報', _buildGuardianInfo()),
              _buildSection('受給者証', _buildCertInfo()),
              _buildSection('定期利用', _buildRegularInfo()),
              _buildSection('送迎場所', _buildTransportInfo()),
              _buildSection('備考', _buildNotesInfo()),
            ],
          ),
        ),
      ),
      // ── 画面下固定の保存ボタン ─────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _save,
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _isEditing ? '保存する' : '登録する',
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // ── セクション共通ラッパー ───────────────────────────────────────────

  Widget _buildSection(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Divider(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: child,
          ),
        ],
      ),
    );
  }

  // ── セクション1: 基本情報 ────────────────────────────────────────────

  Widget _buildBasicInfo() {
    return Column(
      children: [
        // 氏名
        TextFormField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: '氏名 *',
            hintText: '例: 山田 太郎',
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? '氏名は必須です' : null,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        // ふりがな
        TextFormField(
          controller: _nameKanaCtrl,
          decoration: InputDecoration(
            labelText: 'ふりがな *',
            hintText: '例: ヤマダ タロウ',
            suffixIcon: TextButton.icon(
              onPressed: _convertKana,
              icon: const Icon(Icons.autorenew, size: 16),
              label: const Text('カナ変換', style: TextStyle(fontSize: 12)),
            ),
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'ふりがなは必須です' : null,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        // 生年月日
        InkWell(
          onTap: _pickBirthday,
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '生年月日',
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
            child: Text(
              _birthday != null
                  ? DateFormat('yyyy年M月d日').format(_birthday!)
                  : '未設定',
              style: TextStyle(
                color: _birthday != null
                    ? AppColors.onSurface
                    : AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 性別
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '性別',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: ['男児', '女児'].map((g) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(g),
                    selected: _gender == g,
                    onSelected: (selected) {
                      setState(() => _gender = selected ? g : null);
                    },
                    selectedColor: AppColors.primary.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: _gender == g
                          ? AppColors.primary
                          : AppColors.onSurface,
                      fontWeight: _gender == g
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 電話番号
        TextFormField(
          controller: _phoneCtrl,
          decoration: const InputDecoration(
            labelText: '電話番号',
            hintText: '例: 090-1234-5678',
            prefixIcon: Icon(Icons.phone, size: 18),
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d\-\(\)\+]')),
          ],
          textInputAction: TextInputAction.next,
        ),
      ],
    );
  }

  // ── セクション2: 保護者情報 ──────────────────────────────────────────

  Widget _buildGuardianInfo() {
    return Column(
      children: [
        TextFormField(
          controller: _guardianNameCtrl,
          decoration: const InputDecoration(
            labelText: '保護者氏名',
            hintText: '例: 山田 花子',
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _guardianPhoneCtrl,
          decoration: const InputDecoration(
            labelText: '保護者電話番号',
            hintText: '例: 080-9876-5432',
            prefixIcon: Icon(Icons.phone, size: 18),
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d\-\(\)\+]')),
          ],
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _lineUserIdCtrl,
          decoration: const InputDecoration(
            labelText: 'LINE User ID',
            hintText: '例: U1234567890abcdef...',
            prefixIcon: Icon(Icons.chat_bubble_outline, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
      ],
    );
  }

  // ── セクション3: 受給者証 ─────────────────────────────────────────────

  Widget _buildCertInfo() {
    return Column(
      children: [
        TextFormField(
          controller: _recipientCertNumberCtrl,
          decoration: const InputDecoration(
            labelText: '受給者証番号',
            hintText: '例: 1234567890',
            prefixIcon: Icon(Icons.badge_outlined, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        // 受給者証有効期限
        InkWell(
          onTap: _pickCertExpiry,
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '受給者証有効期限',
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _certExpiry != null
                        ? DateFormat('yyyy年M月d日').format(_certExpiry!)
                        : '未設定',
                    style: TextStyle(
                      color: _certExpiry != null
                          ? (_certExpiry!
                                  .isBefore(DateTime.now().add(const Duration(days: 30)))
                              ? AppColors.error
                              : AppColors.onSurface)
                          : AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_certExpiry != null)
                  GestureDetector(
                    onTap: () => setState(() => _certExpiry = null),
                    child: const Icon(Icons.clear, size: 16,
                        color: AppColors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 月間支給量
        Row(
          children: [
            const Expanded(
              child: Text(
                '月間支給量（日）',
                style: TextStyle(color: AppColors.onSurface),
              ),
            ),
            _buildNumberInput(
              value: _monthlyAvailableDays,
              min: 1,
              max: 31,
              onChanged: (v) => setState(() => _monthlyAvailableDays = v),
            ),
          ],
        ),
      ],
    );
  }

  // ── セクション4: 定期利用 ─────────────────────────────────────────────

  Widget _buildRegularInfo() {
    const dayLabels = {1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '定期利用曜日',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: dayLabels.entries.map((entry) {
            final isSelected = _regularDays.contains(entry.key);
            return FilterChip(
              label: Text(entry.value),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    _regularDays.add(entry.key);
                    _regularDays.sort();
                  } else {
                    _regularDays.remove(entry.key);
                  }
                });
              },
              selectedColor: AppColors.secondary.withValues(alpha: 0.2),
              checkmarkColor: AppColors.secondary,
              labelStyle: TextStyle(
                color: isSelected ? AppColors.secondary : AppColors.onSurface,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            );
          }).toList(),
        ),
        if (_isEditing) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '当月利用日数',
                  style: TextStyle(color: AppColors.onSurface),
                ),
              ),
              _buildNumberInput(
                value: _currentMonthUsedDays,
                min: 0,
                max: _monthlyAvailableDays,
                onChanged: (v) => setState(() => _currentMonthUsedDays = v),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── セクション5: 送迎場所 ─────────────────────────────────────────────

  Widget _buildTransportInfo() {
    const hints = ['例: 〇〇小学校', '例: ○○公民館', '例: 自宅'];
    const icons = [Icons.directions_car, Icons.directions_car, Icons.home_outlined];
    return Column(
      children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          TextFormField(
            controller: _transportCtrl(i),
            decoration: InputDecoration(
              labelText: '送迎場所${i + 1}',
              hintText: hints[i],
              prefixIcon: Icon(icons[i], size: 18),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 6),
          _buildLocationCoordRow(i),
        ],
        const SizedBox(height: 6),
        const Text(
          '※ 座標は送迎ルート最適化で使用します。未解決のままでも保存できます'
          '（送迎計画実行時に自動ジオコーディングされます）。',
          style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
        ),
      ],
    );
  }

  /// 送迎場所 i の状態チップ + 操作ボタン行
  Widget _buildLocationCoordRow(int i) {
    final text = _transportCtrl(i).text.trim();
    if (!TransportLocationResolver.isResolvable(text)) {
      return const SizedBox.shrink();
    }
    final coord = _locCoord(i);
    final busy = _locBusy[i];
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TransportLocationStatusChip(status: _locStatus[i], coord: coord),
          if (coord != null)
            Text(
              '${coord.lat.toStringAsFixed(5)}, ${coord.lng.toStringAsFixed(5)}',
              style: const TextStyle(
                  fontSize: 10.5, color: AppColors.onSurfaceVariant, fontFamily: 'monospace'),
            ),
          _smallAction(
            icon: Icons.search,
            label: _locStatus[i] == Customer.locFailed ? 'リトライ' : '候補を取得',
            busy: busy,
            onTap: busy ? null : () => _fetchCandidates(i),
          ),
          // 最終手段: geocode 0 件・候補なしでも常に押下可能
          _smallAction(
            icon: Icons.add_location_alt_outlined,
            label: '地図から直接指定',
            onTap: busy ? null : () => _pickOnMap(i),
          ),
          _smallAction(
            icon: Icons.edit_location_alt_outlined,
            label: '地図で微調整',
            onTap: busy ? null : () => _adjustOnMap(i),
          ),
          if (coord != null || _locStatus[i] != Customer.locUnresolved)
            _smallAction(
              icon: Icons.clear,
              label: 'クリア',
              color: AppColors.onSurfaceVariant,
              onTap: busy ? null : () => _clearCoord(i),
            ),
        ],
      ),
    );
  }

  Widget _smallAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool busy = false,
    Color color = AppColors.primary,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 11.5),
      ),
      icon: busy
          ? const SizedBox(
              width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 14),
      label: Text(label),
    );
  }

  // ── セクション6: 備考 ─────────────────────────────────────────────────

  Widget _buildNotesInfo() {
    return TextFormField(
      controller: _notesCtrl,
      decoration: const InputDecoration(
        labelText: '備考',
        hintText: '例: アレルギー情報、特記事項など',
        alignLabelWithHint: true,
      ),
      maxLines: 3,
      textInputAction: TextInputAction.newline,
    );
  }

  // ── 数値入力ウィジェット ────────────────────────────────────────────

  Widget _buildNumberInput({
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          color: AppColors.primary,
          onPressed: value > min ? () => onChanged(value - 1) : null,
          iconSize: 24,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.onSurface,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          color: AppColors.primary,
          onPressed: value < max ? () => onChanged(value + 1) : null,
          iconSize: 24,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }
}
