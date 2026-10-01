import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/customer_export_service.dart';
import '../services/customer_import_service.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import '../utils/file_saver.dart';

/// 利用者インポート（Excel / CSV）
///
/// 遷移: 1. ファイル選択 → 2. プレビュー → 3. 重複確認ダイアログ → 4. 結果
/// 仕様正本: linkday_customer_sample.xlsx「顧客マスタ」16 列
class CustomerImportScreen extends StatefulWidget {
  const CustomerImportScreen({super.key});

  @override
  State<CustomerImportScreen> createState() => _CustomerImportScreenState();
}

enum _Step { pick, preview, result }

/// 重複ダイアログの「今後すべて〜」一括指定
enum _BulkMode { ask, overwriteAll, skipAll }

class _CustomerImportScreenState extends State<CustomerImportScreen> {
  _Step _step = _Step.pick;
  bool _busy = false;
  String? _error;

  ImportPreview? _preview;
  CustomerImportResult? _result;
  _BulkMode _bulk = _BulkMode.ask;
  bool _didImport = false;

  // ── 1. ファイル選択 ───────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final f = picked.files.single;
      final bytes = f.bytes;
      if (bytes == null) {
        throw const FormatException('ファイルの読み込みに失敗しました（データが空）');
      }
      debugPrint('[CustomerImportScreen] picked: ${f.name} (${bytes.length} bytes)');
      final preview = CustomerImportService.instance.parse(
        fileName: f.name,
        bytes: bytes,
      );
      debugPrint('[CustomerImportScreen] preview: total=${preview.totalRows}, '
          'valid=${preview.validRows}, errors=${preview.errorRows}, '
          'dup=${preview.duplicateRows}, enc=${preview.encoding.label}');
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _bulk = _BulkMode.ask;
        _step = _Step.preview;
        _busy = false;
      });
    } catch (e) {
      debugPrint('[CustomerImportScreen] parse failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '読み込みエラー: $e';
      });
    }
  }

  /// テスト用: 解析済みプレビューを直接セットしてプレビュー画面へ遷移
  @visibleForTesting
  void debugSetPreview(ImportPreview preview) {
    setState(() {
      _preview = preview;
      _bulk = _BulkMode.ask;
      _error = null;
      _step = _Step.preview;
      _busy = false;
    });
  }

  /// テスト用: 実行ボタン相当（[overwriteAll] で重複を全て上書き）
  @visibleForTesting
  Future<void> debugExecute({bool overwriteAll = false}) {
    if (overwriteAll) _bulk = _BulkMode.overwriteAll;
    return _execute();
  }

  // ── 3. 重複確認ダイアログ ─────────────────────────────────────

  Future<DuplicateAction?> _resolveDuplicate(ParsedCustomerRow row) async {
    switch (_bulk) {
      case _BulkMode.overwriteAll:
        return DuplicateAction.overwrite;
      case _BulkMode.skipAll:
        return DuplicateAction.skip;
      case _BulkMode.ask:
        break;
    }
    if (!mounted) return DuplicateAction.skip;
    final dup = row.duplicate!;
    final c = row.customer!;

    final res = await showDialog<(_DupChoice, bool)>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DuplicateDialog(
        row: row,
        existingName: dup.existing.name,
        existingCert: dup.existing.recipientCertNumber,
        existingBirthday: dup.existing.birthday,
        kind: dup.kind,
        incomingName: c.name,
      ),
    );
    // ダイアログを閉じた（null）→ 既定スキップ
    if (res == null) return DuplicateAction.skip;
    final (choice, applyAll) = res;
    switch (choice) {
      case _DupChoice.overwrite:
        if (applyAll) _bulk = _BulkMode.overwriteAll;
        return DuplicateAction.overwrite;
      case _DupChoice.skip:
        if (applyAll) _bulk = _BulkMode.skipAll;
        return DuplicateAction.skip;
      case _DupChoice.abort:
        return DuplicateAction.abort;
    }
  }

  // ── 4. 実行 ──────────────────────────────────────────────────

  Future<void> _execute() async {
    final p = _preview;
    if (p == null) return;
    if (p.validRows == 0) {
      _snack('取り込める有効行がありません', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await CustomerImportService.instance.execute(
        p,
        resolveDuplicate: _resolveDuplicate,
      );
      if (!mounted) return;
      _didImport = result.imported + result.overwritten > 0;
      setState(() {
        _result = result;
        _step = _Step.result;
        _busy = false;
      });
    } catch (e) {
      debugPrint('[CustomerImportScreen] execute failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '取り込みエラー: $e';
      });
    }
  }

  // ── テンプレート / エクスポート ───────────────────────────────

  Future<void> _download(String kind) async {
    try {
      final svc = CustomerExportService.instance;
      final stamp = _dateStamp();
      switch (kind) {
        case 'tpl_xlsx':
          await saveBytesToFile(
            bytes: svc.buildTemplateXlsx(),
            fileName: 'linkday_customer_sample.xlsx',
            mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          );
        case 'tpl_csv':
          await saveBytesToFile(
            bytes: svc.buildTemplateCsv(),
            fileName: 'linkday_customer_sample.csv',
            mimeType: 'text/csv;charset=utf-8',
          );
        case 'tpl_blank_xlsx':
          await saveBytesToFile(
            bytes: svc.buildTemplateXlsx(withSample: false),
            fileName: 'linkday_customer_template.xlsx',
            mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          );
        case 'export_xlsx':
          final customers = CustomerService.instance.getAllCustomers();
          await saveBytesToFile(
            bytes: svc.exportCustomersXlsx(customers),
            fileName: 'linkday_customers_$stamp.xlsx',
            mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          );
          _snack('${customers.length} 件をエクスポートしました');
        case 'export_csv':
          final customers = CustomerService.instance.getAllCustomers();
          await saveBytesToFile(
            bytes: svc.exportCustomersCsv(customers),
            fileName: 'linkday_customers_$stamp.csv',
            mimeType: 'text/csv;charset=utf-8',
          );
          _snack('${customers.length} 件をエクスポートしました');
      }
    } catch (e) {
      _snack('ダウンロードに失敗しました: $e', isError: true);
    }
  }

  String _dateStamp() {
    final n = DateTime.now();
    return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}';
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? AppColors.error : AppColors.success,
    ));
  }

  // ── build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        // Navigator.pop の戻り値は _close() 経由で返す
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('利用者インポート'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _close,
          ),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'テンプレート / エクスポート',
              icon: const Icon(Icons.download_outlined),
              onSelected: _download,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'tpl_xlsx',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.table_view),
                    title: Text('サンプル付きテンプレート (.xlsx)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'tpl_csv',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.description_outlined),
                    title: Text('サンプル付きテンプレート (.csv UTF-8)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'tpl_blank_xlsx',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.grid_on),
                    title: Text('空テンプレート (.xlsx)'),
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'export_xlsx',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.upload_file),
                    title: Text('登録中の利用者をエクスポート (.xlsx)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export_csv',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.upload_file_outlined),
                    title: Text('登録中の利用者をエクスポート (.csv)'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: _StepIndicator(step: _step),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: _Banner(
                    icon: Icons.error_outline,
                    color: AppColors.error,
                    text: _error!,
                  ),
                ),
              Expanded(
                child: _busy
                    ? const Center(child: CircularProgressIndicator())
                    : switch (_step) {
                        _Step.pick => _buildPickStep(),
                        _Step.preview => _buildPreviewStep(),
                        _Step.result => _buildResultStep(),
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _close() {
    Navigator.of(context).pop(_didImport);
  }

  // ── Step 1 UI ────────────────────────────────────────────────

  Widget _buildPickStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4), width: 1.5),
            ),
            child: Column(
              children: [
                const Icon(Icons.upload_file, size: 56, color: AppColors.primary),
                const SizedBox(height: 12),
                const Text('Excel (.xlsx) または CSV を選択',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text(
                  'CSV は UTF-8 / Shift_JIS を自動判定します',
                  style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('ファイルを選択'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('取り込み列（16 列・正本: 顧客マスタ シート）',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (int i = 0; i < kCustomerImportHeaders.length; i++)
                Chip(
                  label: Text(kCustomerImportHeaders[i],
                      style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: i == 0
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : null,
                  side: i == 0
                      ? const BorderSide(color: AppColors.primary)
                      : BorderSide.none,
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('※ 氏名は必須。それ以外は空欄可。性別は「男児/女児」、'
              '定期利用曜日は「月,水,金」形式。受給者証番号は文字列のまま保存します。',
              style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _download('tpl_xlsx'),
            icon: const Icon(Icons.download),
            label: const Text('サンプル付きテンプレートをダウンロード (.xlsx)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _download('tpl_csv'),
            icon: const Icon(Icons.download),
            label: const Text('サンプル付きテンプレートをダウンロード (.csv)'),
          ),
        ],
      ),
    );
  }

  // ── Step 2 UI ────────────────────────────────────────────────

  Widget _buildPreviewStep() {
    final p = _preview!;
    final sample = p.rows.take(5).toList();
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ファイル情報
                _Card(
                  title: 'ファイル',
                  icon: Icons.insert_drive_file_outlined,
                  child: Column(
                    children: [
                      _kv('ファイル名', p.fileName),
                      _kv('形式', p.fileType == ImportFileType.xlsx
                          ? 'Excel (.xlsx) / シート「$kCustomerMasterSheetName」'
                          : 'CSV'),
                      _kv('文字コード', p.encoding.label),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 集計
                _Card(
                  title: '集計',
                  icon: Icons.summarize_outlined,
                  child: Row(
                    children: [
                      _Stat('全行数', p.totalRows, AppColors.onSurface),
                      _Stat('有効', p.validRows, AppColors.success),
                      _Stat('エラー', p.errorRows, AppColors.error),
                      _Stat('重複候補', p.duplicateRows, AppColors.warning),
                    ],
                  ),
                ),
                if (p.headerWarnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    icon: Icons.view_column_outlined,
                    color: AppColors.warning,
                    text: '${p.headerWarnings.length} 列がヘッダーに見つかりません'
                        '（該当列は空として取り込みます）\n'
                        '${p.headerWarnings.take(4).join('\n')}'
                        '${p.headerWarnings.length > 4 ? '\n…' : ''}',
                  ),
                ],
                if (p.expiredCount + p.expiringSoonCount > 0) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    icon: Icons.badge_outlined,
                    color: p.expiredCount > 0 ? AppColors.error : AppColors.warning,
                    text: '受給者証期限: 超過 ${p.expiredCount} 件 / '
                        '30日未満 ${p.expiringSoonCount} 件',
                  ),
                ],
                const SizedBox(height: 12),
                // サンプルテーブル
                _Card(
                  title: 'サンプル（先頭 ${sample.length} 行）',
                  icon: Icons.table_rows_outlined,
                  padding: EdgeInsets.zero,
                  child: _SampleTable(rows: sample),
                ),
                if (p.errorRows > 0) ...[
                  const SizedBox(height: 12),
                  _Card(
                    title: 'エラー行',
                    icon: Icons.error_outline,
                    child: Column(
                      children: [
                        for (final r in p.rows.where((r) => !r.isValid))
                          _issueTile(r.rowNumber, r.errors.join(' / '), AppColors.error),
                      ],
                    ),
                  ),
                ],
                if (p.rows.any((r) => r.isValid && r.warnings.isNotEmpty)) ...[
                  const SizedBox(height: 12),
                  _Card(
                    title: '警告（取り込みは可能）',
                    icon: Icons.warning_amber_outlined,
                    child: Column(
                      children: [
                        for (final r in p.rows.where((r) => r.isValid && r.warnings.isNotEmpty))
                          _issueTile(r.rowNumber,
                              '${r.customer!.name}: ${r.warnings.join(' / ')}',
                              AppColors.warning),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
        // 実行 / キャンセル
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _preview = null;
                    _error = null;
                    _step = _Step.pick;
                  }),
                  child: const Text('キャンセル'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: p.validRows == 0 ? null : _execute,
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text('実行（${p.validRows} 件）'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Step 4 UI ────────────────────────────────────────────────

  Widget _buildResultStep() {
    final r = _result!;
    final expired = r.certAlerts.where((a) => a.$2 == CertAlertKind.expired).toList();
    final soon = r.certAlerts.where((a) => a.$2 == CertAlertKind.expiringSoon).toList();
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  r.aborted ? Icons.cancel_outlined : Icons.check_circle_outline,
                  size: 56,
                  color: r.aborted ? AppColors.warning : AppColors.success,
                ),
                const SizedBox(height: 8),
                Text(
                  r.aborted ? '取り込みを中止しました（途中まで反映）' : '取り込みが完了しました',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                _Card(
                  title: '結果',
                  icon: Icons.summarize_outlined,
                  child: Row(
                    children: [
                      _Stat('取り込み', r.imported, AppColors.success),
                      _Stat('上書き', r.overwritten, AppColors.info),
                      _Stat('スキップ', r.skipped, AppColors.onSurfaceVariant),
                      _Stat('エラー', r.errorCount, AppColors.error),
                    ],
                  ),
                ),
                if (expired.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Card(
                    title: '受給者証期限 超過（${expired.length} 件）',
                    icon: Icons.badge_outlined,
                    color: AppColors.error,
                    child: Column(
                      children: [
                        for (final (row, _) in expired)
                          _certTile(row, AppColors.error),
                      ],
                    ),
                  ),
                ],
                if (soon.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Card(
                    title: '受給者証期限 30日未満（${soon.length} 件）',
                    icon: Icons.badge_outlined,
                    color: AppColors.warning,
                    child: Column(
                      children: [
                        for (final (row, _) in soon)
                          _certTile(row, AppColors.warning),
                      ],
                    ),
                  ),
                ],
                if (r.errors.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Card(
                    title: 'エラー行一覧',
                    icon: Icons.error_outline,
                    child: Column(
                      children: [
                        for (final (rowNo, msg) in r.errors)
                          _issueTile(rowNo, msg, AppColors.error),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 80),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _preview = null;
                    _result = null;
                    _error = null;
                    _step = _Step.pick;
                  }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('別のファイル', softWrap: false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: FilledButton.icon(
                  onPressed: _close,
                  icon: const Icon(Icons.people_outline),
                  label: const Text('顧客一覧へ戻る'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── 小部品 ───────────────────────────────────────────────────

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 84,
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.onSurfaceVariant))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  Widget _issueTile(int rowNo, String msg, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('行 $rowNo',
                  style: TextStyle(
                      fontSize: 11, color: color, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(msg, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  Widget _certTile(ParsedCustomerRow row, Color color) {
    final c = row.customer!;
    final exp = c.recipientCertExpiry!;
    final days = c.certExpiryDaysLeft ?? 0;
    final label = days < 0 ? '${-days} 日超過' : '残り $days 日';
    return _issueTile(
      row.rowNumber,
      '${c.name}  期限 ${exp.year}/${exp.month.toString().padLeft(2, '0')}/${exp.day.toString().padLeft(2, '0')}（$label）',
      color,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 重複確認ダイアログ
// ════════════════════════════════════════════════════════════════

enum _DupChoice { overwrite, skip, abort }

class _DuplicateDialog extends StatefulWidget {
  final ParsedCustomerRow row;
  final String existingName;
  final String? existingCert;
  final DateTime? existingBirthday;
  final DuplicateMatchKind kind;
  final String incomingName;

  const _DuplicateDialog({
    required this.row,
    required this.existingName,
    required this.existingCert,
    required this.existingBirthday,
    required this.kind,
    required this.incomingName,
  });

  @override
  State<_DuplicateDialog> createState() => _DuplicateDialogState();
}

class _DuplicateDialogState extends State<_DuplicateDialog> {
  bool _applyAll = false;

  String _fmt(DateTime? d) => d == null
      ? '—'
      : '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = widget.row.customer!;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.people_alt_outlined, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text('重複候補（行 ${widget.row.rowNumber}）',
                style: const TextStyle(fontSize: 16)),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('判定: ${widget.kind.label}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 12),
            _row('既存', widget.existingName,
                '受給者証 ${widget.existingCert ?? '—'} / 生年月日 ${_fmt(widget.existingBirthday)}'),
            const Divider(height: 16),
            _row('ファイル', c.name,
                '受給者証 ${c.recipientCertNumber ?? '—'} / 生年月日 ${_fmt(c.birthday)}'),
            const SizedBox(height: 12),
            const Text(
              '「上書き」は既存の ID を維持したまま内容をファイルの値で更新します。'
              '「スキップ」はこの行を取り込みません（既定）。',
              style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _applyAll,
              onChanged: (v) => setState(() => _applyAll = v ?? false),
              title: const Text('今後の重複にも同じ選択を適用する',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 6,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (_DupChoice.abort, false)),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: const Text('中止'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14)),
          onPressed: () => Navigator.pop(context, (_DupChoice.overwrite, _applyAll)),
          child: const Text('上書き'),
        ),
        FilledButton(
          autofocus: true,
          style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14)),
          onPressed: () => Navigator.pop(context, (_DupChoice.skip, _applyAll)),
          child: const Text('スキップ'),
        ),
      ],
    );
  }

  Widget _row(String label, String name, String sub) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(sub,
                    style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      );
}

// ════════════════════════════════════════════════════════════════
// 共通小部品
// ════════════════════════════════════════════════════════════════

class _StepIndicator extends StatelessWidget {
  final _Step step;
  const _StepIndicator({required this.step});

  @override
  Widget build(BuildContext context) {
    const labels = ['ファイル選択', 'プレビュー', '結果'];
    final current = step.index;
    return Row(
      children: List.generate(labels.length, (i) {
        final done = i < current;
        final active = i == current;
        final color = done
            ? AppColors.success
            : active
                ? AppColors.primary
                : AppColors.divider;
        return Expanded(
          child: Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: color,
                child: done
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text('${i + 1}',
                        style: TextStyle(
                            fontSize: 11,
                            color: active ? Colors.white : AppColors.onSurfaceVariant)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  labels[i],
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active ? AppColors.primary : AppColors.onSurfaceVariant,
                  ),
                ),
              ),
              if (i < labels.length - 1)
                Container(
                  width: 18,
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: done ? AppColors.success : AppColors.divider,
                ),
            ],
          ),
        );
      }),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  const _Card({
    required this.title,
    required this.icon,
    required this.child,
    this.color,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Icon(icon, size: 18, color: c),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600, color: c)),
                ),
              ],
            ),
          ),
          Padding(
            padding: padding ?? const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Stat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text('$value',
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700, color: color)),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// サンプル行テーブル（横スクロール・ヘッダー和名）
class _SampleTable extends StatelessWidget {
  final List<ParsedCustomerRow> rows;
  const _SampleTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: Text('データ行がありません', style: TextStyle(fontSize: 12)),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 40,
        columnSpacing: 14,
        horizontalMargin: 8,
        headingTextStyle: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.onSurface),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: AppColors.onSurface),
        columns: [
          const DataColumn(label: Text('行')),
          const DataColumn(label: Text('状態')),
          for (final h in kCustomerImportHeaders) DataColumn(label: Text(h)),
        ],
        rows: [
          for (final r in rows)
            DataRow(
              color: WidgetStateProperty.resolveWith((_) => !r.isValid
                  ? AppColors.error.withValues(alpha: 0.06)
                  : r.hasDuplicate
                      ? AppColors.warning.withValues(alpha: 0.08)
                      : null),
              cells: [
                DataCell(Text('${r.rowNumber}')),
                DataCell(_statusChip(r)),
                for (int i = 0; i < kCustomerImportHeaders.length; i++)
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        _cellText(r, i),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 正規化後の値を優先表示（曜日・性別・カナなど変換結果が見える）
  String _cellText(ParsedCustomerRow r, int i) {
    final c = r.customer;
    if (c == null) return r.rawCells[i];
    switch (i) {
      case 1:
        return c.nameKana;
      case 3:
        return c.gender ?? r.rawCells[i];
      case 11:
        return c.regularDays.isEmpty
            ? r.rawCells[i]
            : '${c.regularDayLabels.join(',')}  [${c.regularDays.join(',')}]';
      default:
        return r.rawCells[i];
    }
  }

  Widget _statusChip(ParsedCustomerRow r) {
    String label;
    Color color;
    if (!r.isValid) {
      label = 'エラー';
      color = AppColors.error;
    } else if (r.hasDuplicate) {
      label = '重複';
      color = AppColors.warning;
    } else if (r.certAlert == CertAlertKind.expired) {
      label = '期限超過';
      color = AppColors.error;
    } else if (r.certAlert == CertAlertKind.expiringSoon) {
      label = '期限間近';
      color = AppColors.warning;
    } else {
      label = 'OK';
      color = AppColors.success;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          softWrap: false,
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
