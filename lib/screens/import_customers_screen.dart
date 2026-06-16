import 'dart:typed_data';

// excel の Border/BorderStyle が Flutter の同名クラスと衝突するため hide する
import 'package:excel/excel.dart' hide Border, BorderStyle;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/customer_service.dart';
import '../theme/app_theme.dart';

// Excel カラム名 → フィールド名 の自動マッピング定義
const Map<String, String> _autoMappingRules = {
  '氏名': 'name', '名前': 'name', '姓名': 'name',
  'ふりがな': 'nameKana', 'フリガナ': 'nameKana', 'かな': 'nameKana',
  'カナ': 'nameKana', '読み': 'nameKana', '振り仮名': 'nameKana',
  '生年月日': 'birthday', '誕生日': 'birthday',
  '性別': 'gender',
  '電話番号': 'phone', '電話': 'phone', 'TEL': 'phone', 'tel': 'phone',
  '保護者氏名': 'guardianName', '保護者名': 'guardianName', '保護者': 'guardianName',
  '保護者電話': 'guardianPhone', '保護者電話番号': 'guardianPhone',
  'LINE ID': 'lineUserId', 'LINE_ID': 'lineUserId', 'LINEユーザーID': 'lineUserId',
  '受給者証番号': 'recipientCertNumber', '受給者番号': 'recipientCertNumber',
  '受給者証期限': 'recipientCertExpiry', '有効期限': 'recipientCertExpiry',
  '月間支給量': 'monthlyAvailableDays', '支給量': 'monthlyAvailableDays',
  '定期利用曜日': 'regularDays', '定期曜日': 'regularDays',
  '送迎場所1': 'transportLocation1', '送迎1': 'transportLocation1',
  '送迎場所2': 'transportLocation2', '送迎2': 'transportLocation2',
  '送迎場所3': 'transportLocation3', '送迎3': 'transportLocation3',
  '備考': 'notes', 'メモ': 'notes',
};

// フィールド名 → 日本語ラベル
const Map<String, String> _fieldLabels = {
  'name': '氏名 *',
  'nameKana': 'ふりがな *',
  'birthday': '生年月日',
  'gender': '性別',
  'phone': '電話番号',
  'guardianName': '保護者氏名',
  'guardianPhone': '保護者電話',
  'lineUserId': 'LINE User ID',
  'recipientCertNumber': '受給者証番号',
  'recipientCertExpiry': '受給者証期限',
  'monthlyAvailableDays': '月間支給量',
  'regularDays': '定期利用曜日',
  'transportLocation1': '送迎場所1',
  'transportLocation2': '送迎場所2',
  'transportLocation3': '送迎場所3',
  'notes': '備考',
};

class ImportCustomersScreen extends StatefulWidget {
  const ImportCustomersScreen({super.key});

  @override
  State<ImportCustomersScreen> createState() => _ImportCustomersScreenState();
}

class _ImportCustomersScreenState extends State<ImportCustomersScreen> {
  // ── ステップ管理 ────────────────────────────────────────────────────
  int _step = 0; // 0:ファイル選択, 1:プレビュー, 2:マッピング, 3:オプション, 4:実行

  // ── Excel データ ────────────────────────────────────────────────────
  String? _fileName;
  Excel? _excel;
  String? _selectedSheet;
  List<String> _sheetNames = [];
  List<List<dynamic>> _rows = [];
  List<String> _headers = [];

  // ── マッピング ──────────────────────────────────────────────────────
  // fieldName → Excelのカラムインデックス
  Map<String, int?> _columnMapping = {};

  // ── オプション ──────────────────────────────────────────────────────
  bool _autoKana = true;
  bool _skipDuplicates = true;

  // ── インポート結果 ──────────────────────────────────────────────────
  ImportResult? _result;
  bool _isImporting = false;

  // ── Step 0: ファイル選択 ─────────────────────────────────────────────

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        if (!mounted) return;
        _showError('ファイルの読み込みに失敗しました');
        return;
      }

      final excel = Excel.decodeBytes(Uint8List.fromList(bytes));
      final sheetNames = excel.tables.keys.toList();

      if (sheetNames.isEmpty) {
        if (!mounted) return;
        _showError('有効なシートが見つかりません');
        return;
      }

      setState(() {
        _fileName = file.name;
        _excel = excel;
        _sheetNames = sheetNames;
        _selectedSheet = sheetNames.first;
        _loadSheet(sheetNames.first);
        _step = 1;
      });
    } catch (e) {
      if (!mounted) return;
      _showError('ファイルの解析に失敗しました: $e');
    }
  }

  void _loadSheet(String sheetName) {
    if (_excel == null) return;
    final sheet = _excel!.tables[sheetName];
    if (sheet == null) return;

    final rawRows = sheet.rows;
    if (rawRows.isEmpty) return;

    // ヘッダー行を取得
    final headerRow = rawRows[0];
    _headers = headerRow.map((cell) => cell?.value?.toString() ?? '').toList();

    // 全行をデータとして保持
    // excel 2.1.0 では日付セルの value は DateTime 型で返る
    _rows = rawRows
        .map((row) => row.map((cell) => cell?.value).toList())
        .toList();

    // 自動マッピングを実行
    _buildAutoMapping();
  }

  void _buildAutoMapping() {
    _columnMapping = {for (final key in _fieldLabels.keys) key: null};
    for (var i = 0; i < _headers.length; i++) {
      final header = _headers[i].trim();
      final fieldName = _autoMappingRules[header];
      if (fieldName != null && _columnMapping.containsKey(fieldName)) {
        _columnMapping[fieldName] = i;
      }
    }
  }

  // ── Step 4: インポート実行 ────────────────────────────────────────────

  Future<void> _executeImport() async {
    // バリデーション: 氏名が必須
    if (_columnMapping['name'] == null) {
      _showError('「氏名」のカラムマッピングが必要です');
      return;
    }

    setState(() {
      _isImporting = true;
      _result = null;
    });

    try {
      // columnMapping を int Map に変換（null を除く）
      final mapping = <String, int>{};
      _columnMapping.forEach((key, value) {
        if (value != null) mapping[key] = value;
      });

      final config = ImportConfig(
        columnMapping: mapping,
        autoKana: _autoKana,
        skipDuplicates: _skipDuplicates,
      );

      final result = await CustomerService.instance.importFromExcel(
        _rows,
        config,
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _isImporting = false;
        _step = 4;
      });
    } catch (e) {
      if (!mounted) return;
      _showError('インポート中にエラーが発生しました: $e');
      setState(() => _isImporting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
      ),
    );
  }

  // ── ビルド ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Excel一括インポート'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStepIndicator(),
            const SizedBox(height: 20),
            _buildStepContent(),
          ],
        ),
      ),
    );
  }

  // ── ステップインジケーター ──────────────────────────────────────────

  Widget _buildStepIndicator() {
    final steps = ['ファイル', 'プレビュー', 'マッピング', 'オプション', '完了'];
    return Row(
      children: List.generate(steps.length, (i) {
        final isActive = i == _step;
        final isDone = i < _step;
        return Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: isDone
                          ? AppColors.success
                          : isActive
                              ? AppColors.primary
                              : AppColors.divider,
                      child: isDone
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isActive ? Colors.white : AppColors.onSurfaceVariant,
                              ),
                            ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      steps[i],
                      style: TextStyle(
                        fontSize: 10,
                        color: isActive
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              if (i < steps.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.only(bottom: 20),
                    color: isDone ? AppColors.success : AppColors.divider,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case 0:
        return _buildFileSelectStep();
      case 1:
        return _buildPreviewStep();
      case 2:
        return _buildMappingStep();
      case 3:
        return _buildOptionsStep();
      case 4:
        return _buildResultStep();
      default:
        return const SizedBox();
    }
  }

  // ── Step 0: ファイル選択 ─────────────────────────────────────────────

  Widget _buildFileSelectStep() {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 32),
          GestureDetector(
            onTap: _pickFile,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4),
                  width: 2,
                  style: BorderStyle.solid,
                ),
                borderRadius: BorderRadius.circular(16),
                color: AppColors.primary.withValues(alpha: 0.03),
              ),
              child: Column(
                children: [
                  Icon(Icons.table_chart_outlined,
                      size: 64, color: AppColors.primary.withValues(alpha: 0.6)),
                  const SizedBox(height: 16),
                  const Text(
                    'Excelファイル (.xlsx) を選択',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'クリックしてファイルを選択してください',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('ファイルを選択'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(160, 44),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          _buildExcelFormatGuide(),
        ],
      ),
    );
  }

  Widget _buildExcelFormatGuide() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline, color: AppColors.secondary, size: 18),
              SizedBox(width: 6),
              Text(
                'Excelファイルの形式',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '1行目にヘッダー行が必要です。以下のカラム名を自動認識します：',
            style: TextStyle(fontSize: 13, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              '氏名', 'ふりがな', '生年月日', '性別', '電話番号',
              '保護者氏名', '保護者電話', '受給者証番号', '受給者証期限',
              '月間支給量', '定期利用曜日', '送迎場所1', '送迎場所2', '備考',
            ].map((label) => Chip(
              label: Text(label, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              backgroundColor: Colors.white,
            )).toList(),
          ),
          const SizedBox(height: 8),
          const Text(
            '・定期利用曜日は "月,水,金" のようにカンマ区切りで入力\n'
            '・ふりがなはひらがな・カタカナどちらでも自動変換されます',
            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── Step 1: プレビュー ────────────────────────────────────────────────

  Widget _buildPreviewStep() {
    final previewRows = _rows.length > 11 ? _rows.sublist(0, 11) : _rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ファイル名と件数
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: AppColors.success, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fileName ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${_rows.length - 1} 件のデータ（ヘッダー除く）',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // シート選択
        if (_sheetNames.length > 1) ...[
          const Text('シートを選択:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _selectedSheet,
            items: _sheetNames.map((name) => DropdownMenuItem(
              value: name,
              child: Text(name),
            )).toList(),
            onChanged: (name) {
              if (name != null) {
                setState(() {
                  _selectedSheet = name;
                  _loadSheet(name);
                });
              }
            },
            decoration: const InputDecoration(
              labelText: 'シート名',
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),
        ],
        // プレビューテーブル
        const Text(
          '先頭10行のプレビュー:',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(
              AppColors.primary.withValues(alpha: 0.08),
            ),
            columnSpacing: 16,
            columns: _headers
                .asMap()
                .entries
                .map((e) => DataColumn(
                      label: Text(
                        e.value.isEmpty ? '列${e.key + 1}' : e.value,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ))
                .toList(),
            rows: previewRows.skip(1).map((row) {
              return DataRow(
                cells: List.generate(
                  _headers.length,
                  (i) => DataCell(
                    Text(
                      i < row.length ? (row[i]?.toString() ?? '') : '',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => setState(() => _step = 2),
            child: const Text('次へ: カラムマッピング'),
          ),
        ),
      ],
    );
  }

  // ── Step 2: カラムマッピング ──────────────────────────────────────────

  Widget _buildMappingStep() {
    // ヘッダー選択肢（インデックス付き）
    final headerOptions = <DropdownMenuItem<int?>>[
      const DropdownMenuItem(value: null, child: Text('— 未選択 —')),
      ..._headers.asMap().entries.map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(
                e.value.isEmpty ? '列${e.key + 1}' : e.value,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
    ];

    // 必須フィールド
    const requiredFields = ['name', 'nameKana'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Excelのカラムと項目を対応付けてください。',
          style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 4),
        const Text(
          '自動認識されたカラムはオレンジで表示されます。',
          style: TextStyle(color: AppColors.primary, fontSize: 12),
        ),
        const SizedBox(height: 16),
        // 必須セクション
        _buildMappingGroup('必須項目', requiredFields, headerOptions),
        const SizedBox(height: 16),
        // 任意セクション
        _buildMappingGroup(
          '任意項目',
          _fieldLabels.keys
              .where((k) => !requiredFields.contains(k))
              .toList(),
          headerOptions,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _step = 1),
                child: const Text('戻る'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: () => setState(() => _step = 3),
                child: const Text('次へ: オプション'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMappingGroup(
      String title, List<String> fields, List<DropdownMenuItem<int?>> options) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 8),
        ...fields.map((field) {
          final isAutoMapped = _columnMapping[field] != null;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Row(
                    children: [
                      if (isAutoMapped)
                        const Icon(Icons.auto_awesome,
                            size: 14, color: AppColors.primary),
                      if (isAutoMapped) const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _fieldLabels[field] ?? field,
                          style: TextStyle(
                            fontSize: 13,
                            color: isAutoMapped
                                ? AppColors.primary
                                : AppColors.onSurface,
                            fontWeight: isAutoMapped
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    // ignore: deprecated_member_use
                    value: _columnMapping[field],
                    items: options,
                    onChanged: (v) => setState(() => _columnMapping[field] = v),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      filled: true,
                      fillColor: isAutoMapped
                          ? AppColors.primary.withValues(alpha: 0.05)
                          : Colors.white,
                    ),
                    isExpanded: true,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ── Step 3: オプション ────────────────────────────────────────────────

  Widget _buildOptionsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'インポートオプション',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _buildOptionTile(
          icon: Icons.translate,
          title: 'ふりがなを自動カナ変換',
          subtitle: 'ひらがな・半角カナを全角カタカナに統一します',
          value: _autoKana,
          onChanged: (v) => setState(() => _autoKana = v),
        ),
        const SizedBox(height: 8),
        _buildOptionTile(
          icon: Icons.content_copy_outlined,
          title: '氏名重複をスキップ',
          subtitle: '既に登録されている氏名と同じ顧客はスキップします',
          value: _skipDuplicates,
          onChanged: (v) => setState(() => _skipDuplicates = v),
        ),
        const SizedBox(height: 24),
        // インポートデータのサマリー
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: AppColors.secondary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'インポート内容',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '• ファイル: $_fileName\n'
                '• データ件数: ${_rows.length - 1} 件\n'
                '• マッピング済み: ${_columnMapping.values.where((v) => v != null).length} 項目',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _step = 2),
                child: const Text('戻る'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isImporting ? null : _executeImport,
                icon: _isImporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.upload),
                label:
                    Text(_isImporting ? 'インポート中...' : 'インポート実行'),
              ),
            ),
          ],
        ),
        if (_isImporting) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'データを処理しています...',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: SwitchListTile(
        secondary: Icon(icon, color: AppColors.primary),
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: const TextStyle(
                fontSize: 12, color: AppColors.onSurfaceVariant)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.primary,
      ),
    );
  }

  // ── Step 4: 実行結果 ──────────────────────────────────────────────────

  Widget _buildResultStep() {
    final result = _result;
    if (result == null) return const SizedBox();

    final isSuccess = result.failed == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 結果サマリー
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSuccess
                ? AppColors.success.withValues(alpha: 0.1)
                : AppColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSuccess ? AppColors.success : AppColors.warning,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSuccess ? Icons.check_circle : Icons.warning_amber_rounded,
                color: isSuccess ? AppColors.success : AppColors.warning,
                size: 36,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSuccess ? 'インポート完了' : 'インポート完了（一部エラーあり）',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: isSuccess ? AppColors.success : AppColors.warning,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '成功: ${result.success} 件　失敗: ${result.failed} 件',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // エラー詳細
        if (result.errors.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'エラー詳細:',
            style:
                TextStyle(fontWeight: FontWeight.w600, color: AppColors.error),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: AppColors.error.withValues(alpha: 0.2)),
            ),
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: result.errors
                    .map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '• $e',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.error,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.people),
            label: const Text('顧客一覧へ'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () {
              setState(() {
                _step = 0;
                _fileName = null;
                _excel = null;
                _rows = [];
                _headers = [];
                _columnMapping = {};
                _result = null;
              });
            },
            child: const Text('別のファイルをインポート'),
          ),
        ),
      ],
    );
  }
}
