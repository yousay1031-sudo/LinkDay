import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/customer.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import '../utils/kana_util.dart';

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
      final transportLocations = [
        _transport1Ctrl.text.trim(),
        _transport2Ctrl.text.trim(),
        _transport3Ctrl.text.trim(),
      ].where((s) => s.isNotEmpty).toList();

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
    return Column(
      children: [
        TextFormField(
          controller: _transport1Ctrl,
          decoration: const InputDecoration(
            labelText: '送迎場所1',
            hintText: '例: 〇〇小学校',
            prefixIcon: Icon(Icons.directions_car, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _transport2Ctrl,
          decoration: const InputDecoration(
            labelText: '送迎場所2',
            hintText: '例: ○○公民館',
            prefixIcon: Icon(Icons.directions_car, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _transport3Ctrl,
          decoration: const InputDecoration(
            labelText: '送迎場所3',
            hintText: '例: 自宅',
            prefixIcon: Icon(Icons.home_outlined, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
      ],
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
