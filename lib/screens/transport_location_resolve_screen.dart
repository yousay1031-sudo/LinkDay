import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/customer.dart';
import '../models/geocode_candidate.dart';
import '../services/customer_service.dart';
import '../services/maps_js_service.dart';
import '../services/settings_service.dart';
import '../services/transport_location_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/geocode_candidate_sheet.dart';

/// 解決状況サマリーの record 型
typedef _Status = ({
  int total,
  int resolved,
  int manual,
  int failed,
  int unresolved,
  int suspect,
});

/// 送迎場所の位置確認（一括ジオコーディング）画面 — Day 8
///
/// - 全児童 × 送迎場所1〜3 の解決状況マトリクス
/// - フィルタ: すべて / 未解決のみ / 失敗のみ
/// - 「未解決を一括ジオコーディング」: 200ms 間隔で順次実行
/// - 複数候補 / 自動採用不可キューの解決 UI（候補リスト + ミニ地図）
/// - 「帯広市外・粒度不足の採用を解除」（誤採用データの一括リセット）
class TransportLocationResolveScreen extends StatefulWidget {
  const TransportLocationResolveScreen({super.key});

  @override
  State<TransportLocationResolveScreen> createState() =>
      _TransportLocationResolveScreenState();
}

enum _Filter { all, unresolved, failed }

class _TransportLocationResolveScreenState
    extends State<TransportLocationResolveScreen> {
  List<Customer> _customers = [];
  _Filter _filter = _Filter.all;
  bool _hasApiKey = false;
  bool _changed = false;

  // 一括処理
  bool _running = false;
  bool _cancelRequested = false;
  ResolveProgress? _progress;
  ResolveSummary? _summary;
  final List<PendingSelection> _queue = [];

  @override
  void initState() {
    super.initState();
    debugPrint('[ResolveScreen] initState');
    _load();
    SettingsService.instance.loadJsApiKey().then((k) {
      if (mounted) setState(() => _hasApiKey = (k ?? '').isNotEmpty);
    });
  }

  void _load() {
    final list = CustomerService.instance.getAllCustomers();
    list.sort((a, b) => a.nameKana.compareTo(b.nameKana));
    setState(() => _customers = list);
    final st = TransportLocationResolver.countStatus(list);
    debugPrint('[ResolveScreen] loaded: customers=${list.length}, '
        'locations=${st.total}, resolved=${st.resolved}, manual=${st.manual}, '
        'failed=${st.failed}, unresolved=${st.unresolved}, suspect=${st.suspect}');
  }

  void _snack(String msg, {Color color = AppColors.success}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<GeocodeCandidatesResult> _fetch(String address) =>
      MapsJsService.instance.geocodeCandidates(address);

  // ── 一括解決 ─────────────────────────────────────────────────

  Future<void> _resolveAll() async {
    if (!_hasApiKey) {
      _snack('APIキーが設定されていません。設定画面で登録してください。', color: AppColors.error);
      return;
    }
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      _summary = null;
      _queue.clear();
    });
    try {
      final summary = await TransportLocationResolver.instance.resolveAll(
        _customers,
        fetch: _fetch,
        interval: const Duration(milliseconds: 200),
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      _changed = _changed || summary.apiCalls > 0;
      setState(() {
        _summary = summary;
        _queue.addAll(summary.pendingQueue);
      });
      _load();
      if (_queue.isNotEmpty) {
        final blocked = summary.blocked;
        _snack(
            '${_queue.length} 件は確認が必要です'
            '${blocked > 0 ? '（うち自動採用不可 $blocked 件）' : ''}',
            color: AppColors.warning);
      } else {
        _snack('一括ジオコーディングが完了しました');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('一括処理エラー: $e', color: AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  // ── 個別操作 ─────────────────────────────────────────────────

  Future<void> _resolveSingle(Customer c, int i, {bool force = false}) async {
    if (!_hasApiKey) {
      _snack('APIキーが設定されていません', color: AppColors.error);
      return;
    }
    final (outcome, result, judgement) = await TransportLocationResolver.instance
        .resolveOneDetailed(c, i, fetch: _fetch, force: force);
    if (!mounted) return;
    switch (outcome) {
      case ResolveOutcome.autoAdopted:
        _changed = true;
        _snack('${c.name} 送迎場所${i + 1}: 自動採用しました');
        _load();
      case ResolveOutcome.pendingSelection:
        if (judgement != null && !judgement.allowed) {
          _snack('${c.name} 送迎場所${i + 1}: 自動採用不可（${judgement.reasonText}）。'
              '候補を確認してください。', color: AppColors.warning);
        }
        await _pickForCustomer(c, i, result!.sortedByPreference,
            blockReasons: judgement?.allowed == false
                ? judgement!.reasons
                : const <AutoAdoptBlockReason>[]);
      case ResolveOutcome.failed:
        _changed = true;
        _snack('${c.name} 送迎場所${i + 1}: 該当なし / 取得失敗', color: AppColors.error);
        _load();
      case ResolveOutcome.alreadyResolved:
        // 解決済み → 候補を再表示して選び直し可能に
        await _resolveSingle(c, i, force: true);
      case ResolveOutcome.skippedEmpty:
        break;
    }
  }

  Future<void> _pickForCustomer(
    Customer c,
    int i,
    List<GeocodeCandidate> cands, {
    List<AutoAdoptBlockReason> blockReasons = const [],
  }) async {
    final picked = await showGeocodeCandidateSheet(
      context,
      address: c.transportLocations[i],
      candidates: cands,
      title: '${c.name}  送迎場所${i + 1}',
      blockReasonText: blockReasons.isEmpty
          ? null
          : blockReasons.map((r) => r.shortLabel).join(' / '),
      query: TransportLocationResolver.buildGeocodeQuery(c.transportLocations[i]),
    );
    if (picked == null || !mounted) return;
    final ok = await TransportLocationResolver.instance.adoptCandidate(c, i, picked);
    if (!mounted) return;
    if (!ok) {
      _snack('「${picked.formattedAddress}」は国レベルの座標のため採用できません',
          color: AppColors.error);
      return;
    }
    _changed = true;
    _queue.removeWhere((q) => q.customer.id == c.id && q.index == i);
    _load();
    _snack('${c.name} 送迎場所${i + 1}: ${picked.formattedAddress} を採用');
  }

  Future<void> _adjust(Customer c, int i) async {
    final coord = c.transportCoord(i);
    final settings = SettingsService.instance.getSettings();
    final start = coord != null
        ? LatLng(coord.lat, coord.lng)
        : LatLng(settings.facilityLat ?? 42.9238, settings.facilityLng ?? 143.1966);
    final p = await showAdjustCoordDialog(context,
        initial: start, title: '${c.name} 送迎場所${i + 1}', snippet: c.transportLocations[i]);
    if (p == null || !mounted) return;
    await TransportLocationResolver.instance.adoptManualCoord(c, i, p.latitude, p.longitude);
    _changed = true;
    _load();
  }

  Future<void> _clear(Customer c, int i) async {
    await TransportLocationResolver.instance.clearCoord(c, i);
    _changed = true;
    _load();
  }

  // ── 修正3: 誤採用（帯広市外・粒度不足）の一括解除 ───────────────

  Future<void> _resetSuspect() async {
    final suspects = TransportLocationResolver.findSuspectAdoptions(_customers);
    if (suspects.isEmpty) {
      _snack('帯広市外・粒度不足の採用はありません');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restore, color: AppColors.warning),
            SizedBox(width: 8),
            Expanded(child: Text('誤採用の解除', style: TextStyle(fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('以下 ${suspects.length} 件の自動採用座標を解除し、未解決に戻します。',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              const Text('※ 手動採用（ユーザーが選択した座標）は対象外です。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.onSurfaceVariant)),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final s in suspects)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded,
                                  size: 14, color: AppColors.warning),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${s.customer.name} 送迎場所${s.index + 1}'
                                        '「${s.address}」',
                                        style: const TextStyle(fontSize: 12)),
                                    Text(
                                        '${s.formatted ?? '根拠不明'}  '
                                        '(${s.lat.toStringAsFixed(4)}, '
                                        '${s.lng.toStringAsFixed(4)})  — ${s.reasonText}',
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            color: AppColors.onSurfaceVariant)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.restore, size: 16),
            label: Text('${suspects.length} 件を解除'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = await TransportLocationResolver.instance.resetSuspectAdoptions(_customers);
    if (!mounted) return;
    _changed = true;
    _queue.clear();
    setState(() => _summary = null);
    _load();
    _snack('$n 件を未解決に戻しました。再度ジオコーディングしてください。',
        color: AppColors.warning);
  }

  // ── キュー処理 ───────────────────────────────────────────────

  Future<void> _processQueue() async {
    while (_queue.isNotEmpty) {
      if (!mounted) return;
      final item = _queue.first;
      final action = await showDialog<_QueueAction>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _QueueResolveDialog(item: item, remaining: _queue.length),
      );
      if (!mounted || action == null || action.kind == _QueueKind.close) break;
      switch (action.kind) {
        case _QueueKind.adopt:
          final ok = await TransportLocationResolver.instance
              .adoptCandidate(item.customer, item.index, action.candidate!);
          if (!ok) {
            _snack('国レベルの座標（「日本」）は採用できません', color: AppColors.error);
            break;
          }
          _changed = true;
          _queue.removeAt(0);
        case _QueueKind.skip:
          _queue.removeAt(0);
        case _QueueKind.close:
          break;
      }
      _load();
    }
    if (mounted) setState(() {});
  }

  // ── build ────────────────────────────────────────────────────

  List<(Customer, int)> get _visibleCells {
    final out = <(Customer, int)>[];
    for (final c in _customers) {
      for (int i = 0; i < c.transportLocations.length; i++) {
        if (!TransportLocationResolver.isResolvable(c.transportLocations[i])) continue;
        final st = c.transportStatus(i);
        final resolved = c.isTransportResolved(i);
        switch (_filter) {
          case _Filter.all:
            out.add((c, i));
          case _Filter.unresolved:
            if (!resolved) out.add((c, i));
          case _Filter.failed:
            if (st == Customer.locFailed) out.add((c, i));
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final st = TransportLocationResolver.countStatus(_customers);
    final cells = _visibleCells;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('送迎場所の位置確認'),
          actions: [
            IconButton(
              tooltip: '帯広市外・粒度不足の採用を解除',
              icon: Badge(
                isLabelVisible: st.suspect > 0,
                label: Text('${st.suspect}'),
                backgroundColor: AppColors.warning,
                child: const Icon(Icons.restore),
              ),
              onPressed: _running ? null : _resetSuspect,
            ),
            IconButton(
              tooltip: '再読込',
              icon: const Icon(Icons.refresh),
              onPressed: _running ? null : _load,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(st),
              if (_running) _buildProgress(),
              if (_summary != null && !_running) _buildSummary(_summary!),
              _buildFilterBar(st),
              Expanded(
                child: cells.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        itemCount: _customers.length,
                        itemBuilder: (_, idx) => _buildCustomerCard(_customers[idx]),
                      ),
              ),
            ],
          ),
        ),
        floatingActionButton: _buildFab(st),
      ),
    );
  }

  Widget _buildHeader(_Status st) {
    final done = st.resolved + st.manual;
    final ratio = st.total == 0 ? 0.0 : done / st.total;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.place_outlined, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${_customers.length} 名 / 送迎場所 ${st.total} 件',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text('解決 $done / ${st.total}',
                  style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: AppColors.divider,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _stat('自動採用', st.resolved, AppColors.success.withValues(alpha: 0.8)),
              _stat('手動採用', st.manual, AppColors.success),
              _stat('失敗', st.failed, AppColors.error),
              _stat('未解決', st.unresolved, AppColors.onSurfaceVariant),
            ],
          ),
          if (st.suspect > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 16, color: AppColors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '帯広市外・粒度不足の自動採用が ${st.suspect} 件あります。'
                          '解除して再解決することを推奨します。',
                          style: const TextStyle(fontSize: 11.5, color: AppColors.warning),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _running ? null : _resetSuspect,
                      icon: const Icon(Icons.restore, size: 15),
                      label: Text('帯広市外・粒度不足の採用を解除（${st.suspect}件）',
                          style: const TextStyle(fontSize: 11.5)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.warning,
                        side: BorderSide(color: AppColors.warning.withValues(alpha: 0.6)),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (!_hasApiKey) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.key_off, size: 16, color: AppColors.error),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Google Maps API キーが未設定です。設定画面で登録するとジオコーディングできます。',
                        style: TextStyle(fontSize: 11.5, color: AppColors.error)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, int v, Color color) => Expanded(
        child: Column(
          children: [
            Text('$v', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
            Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.onSurfaceVariant)),
          ],
        ),
      );

  Widget _buildProgress() {
    final p = _progress;
    final total = p?.total ?? 0;
    final done = p?.done ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                  width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  total == 0
                      ? '対象を集計中...'
                      : 'ジオコーディング中 $done / $total 件'
                          '${p?.current != null ? '  —  ${p!.current!.name} 送迎場所${(p.currentIndex ?? 0) + 1}' : ''}',
                  style: const TextStyle(fontSize: 12.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
                child: Text(_cancelRequested ? '停止中…' : '中止'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? null : done / total,
              minHeight: 6,
              backgroundColor: AppColors.divider,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ResolveSummary s) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 18, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '完了: 自動採用 ${s.autoAdopted} / 確認待ち ${s.pending}'
                  '${s.blocked > 0 ? '（自動採用不可 ${s.blocked}）' : ''} / '
                  '失敗 ${s.failed} / 解決済みスキップ ${s.alreadyResolved}'
                  '  （API 呼出 ${s.apiCalls} 回）',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => setState(() => _summary = null),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (_queue.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _processQueue,
                icon: const Icon(Icons.rule, size: 16),
                label: Text('要確認の候補を解決する（${_queue.length} 件）'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterBar(_Status st) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<_Filter>(
              segments: [
                ButtonSegment(value: _Filter.all, label: Text('すべて (${st.total})')),
                ButtonSegment(value: _Filter.unresolved, label: Text('未解決 (${st.unresolved + st.failed})')),
                ButtonSegment(value: _Filter.failed, label: Text('失敗 (${st.failed})')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11.5)),
              ),
              showSelectedIcon: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final msg = switch (_filter) {
      _Filter.all => '送迎場所が登録された利用者がいません',
      _Filter.unresolved => '未解決の送迎場所はありません',
      _Filter.failed => '取得失敗の送迎場所はありません',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_filter == _Filter.all ? Icons.people_outline : Icons.check_circle_outline,
              size: 48, color: AppColors.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(msg, style: const TextStyle(color: AppColors.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildCustomerCard(Customer c) {
    final rows = <Widget>[];
    for (int i = 0; i < c.transportLocations.length; i++) {
      if (!TransportLocationResolver.isResolvable(c.transportLocations[i])) continue;
      final st = c.transportStatus(i);
      final resolved = c.isTransportResolved(i);
      final show = switch (_filter) {
        _Filter.all => true,
        _Filter.unresolved => !resolved,
        _Filter.failed => st == Customer.locFailed,
      };
      if (!show) continue;
      rows.add(_buildLocationRow(c, i));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                  child: Text(c.name.isNotEmpty ? c.name.characters.first : '?',
                      style: const TextStyle(fontSize: 12, color: AppColors.primary)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          ...rows,
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildLocationRow(Customer c, int i) {
    final coord = c.transportCoord(i);
    final st = c.transportStatus(i);
    final inQueue = _queue.any((q) => q.customer.id == c.id && q.index == i);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.divider.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('${i + 1}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.transportLocations[i], style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TransportLocationStatusChip(status: st, coord: coord, compact: true),
                    if (inQueue)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('選択待ち',
                            style: TextStyle(fontSize: 9.5, color: AppColors.warning,
                                fontWeight: FontWeight.w600)),
                      ),
                    if (coord != null)
                      Text('${coord.lat.toStringAsFixed(5)}, ${coord.lng.toStringAsFixed(5)}',
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.onSurfaceVariant,
                              fontFamily: 'monospace')),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '操作',
            icon: const Icon(Icons.more_vert, size: 18),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              switch (v) {
                case 'resolve':
                  if (inQueue) {
                    final q = _queue.firstWhere((q) => q.customer.id == c.id && q.index == i);
                    _pickForCustomer(c, i, q.candidates);
                  } else {
                    _resolveSingle(c, i, force: st != Customer.locUnresolved);
                  }
                case 'adjust':
                  _adjust(c, i);
                case 'clear':
                  _clear(c, i);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'resolve',
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.search, size: 18),
                  title: Text(st == Customer.locFailed
                      ? 'リトライ'
                      : inQueue
                          ? '候補から選択'
                          : '候補を取得'),
                ),
              ),
              const PopupMenuItem(
                value: 'adjust',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.edit_location_alt_outlined, size: 18),
                  title: Text('地図で微調整'),
                ),
              ),
              if (st != Customer.locUnresolved)
                const PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.clear, size: 18),
                    title: Text('座標をクリア'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget? _buildFab(_Status st) {
    if (_running) return null;
    final targets = st.unresolved + st.failed;
    if (_queue.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: _processQueue,
        backgroundColor: AppColors.warning,
        icon: const Icon(Icons.rule),
        label: Text('要確認を解決（${_queue.length}）'),
      );
    }
    return FloatingActionButton.extended(
      onPressed: targets == 0 ? null : _resolveAll,
      backgroundColor: targets == 0 ? AppColors.divider : AppColors.primary,
      icon: const Icon(Icons.travel_explore),
      label: Text(targets == 0 ? 'すべて解決済み' : '未解決を一括ジオコーディング（$targets）'),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 複数候補キュー解決ダイアログ（左: 候補リスト / 右: ミニ地図）
// ════════════════════════════════════════════════════════════════

enum _QueueKind { adopt, skip, close }

class _QueueAction {
  final _QueueKind kind;
  final GeocodeCandidate? candidate;
  const _QueueAction(this.kind, [this.candidate]);
}

class _QueueResolveDialog extends StatefulWidget {
  final PendingSelection item;
  final int remaining;
  const _QueueResolveDialog({required this.item, required this.remaining});

  @override
  State<_QueueResolveDialog> createState() => _QueueResolveDialogState();
}

class _QueueResolveDialogState extends State<_QueueResolveDialog> {
  int _sel = 0;

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final cands = it.candidates;
    final sel = cands.isNotEmpty ? cands[_sel.clamp(0, cands.length - 1)] : null;
    final wide = MediaQuery.of(context).size.width >= 700;

    final list = ListView.separated(
      shrinkWrap: true,
      itemCount: cands.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final c = cands[i];
        final isSel = i == _sel;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _sel = i),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: isSel ? AppColors.primary.withValues(alpha: 0.08) : null,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: isSel ? AppColors.primary : AppColors.divider, width: isSel ? 1.5 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(isSel ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 16, color: isSel ? AppColors.primary : AppColors.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.formattedAddress, style: const TextStyle(fontSize: 12.5)),
                      const SizedBox(height: 2),
                      Text(
                        '${c.typeLabel}'
                        '${c.partialMatch ? ' · 部分一致' : ''}'
                        '${c.isOutsideObihiroBounds ? ' · 帯広市外の可能性' : ''}'
                        '${c.isCountryLevel ? ' · 国レベル（採用不可）' : c.hasPointGranularity ? '' : ' · 粒度不足'}',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: (c.isOutsideObihiroBounds ||
                                    c.isCountryLevel ||
                                    !c.hasPointGranularity)
                                ? AppColors.warning
                                : AppColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    final map = sel == null
        ? const SizedBox.shrink()
        : ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: GoogleMap(
              key: ValueKey('q_${sel.lat}_${sel.lng}'),
              initialCameraPosition: CameraPosition(target: LatLng(sel.lat, sel.lng), zoom: 15),
              markers: {
                for (int i = 0; i < cands.length; i++)
                  Marker(
                    markerId: MarkerId('q_$i'),
                    position: LatLng(cands[i].lat, cands[i].lng),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                        i == _sel ? BitmapDescriptor.hueOrange : BitmapDescriptor.hueAzure),
                  ),
              },
              zoomControlsEnabled: false,
              myLocationButtonEnabled: false,
              mapToolbarEnabled: false,
            ),
          );

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: Row(
        children: [
          const Icon(Icons.rule, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${it.customer.name}  送迎場所${it.index + 1}',
                    style: const TextStyle(fontSize: 15)),
                Text('「${it.address}」 ${cands.length} 件  （残り ${widget.remaining} 件）',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.onSurfaceVariant)),
                if (it.query != it.address)
                  Text('検索クエリ: 「${it.query}」',
                      style: const TextStyle(
                          fontSize: 10.5, color: AppColors.onSurfaceVariant)),
                if (it.isBlockedAutoAdopt)
                  Text('自動採用不可（要確認）: ${it.blockReasonText}',
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.warning,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: wide ? 760 : 520,
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: SingleChildScrollView(child: list)),
                  const SizedBox(width: 12),
                  Expanded(flex: 4, child: SizedBox(height: 300, child: map)),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    list,
                    const SizedBox(height: 10),
                    SizedBox(height: 180, child: map),
                  ],
                ),
              ),
      ),
      actionsOverflowButtonSpacing: 6,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _QueueAction(_QueueKind.close)),
          child: const Text('閉じる'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, const _QueueAction(_QueueKind.skip)),
          child: Text(widget.remaining > 1 ? 'スキップして次へ' : 'スキップ'),
        ),
        FilledButton.icon(
          // 受け入れ基準5: 「日本」レベルの座標はどの経路でも保存させない
          onPressed: (sel == null ||
                  !TransportLocationResolver.isStorableCandidate(sel))
              ? null
              : () => Navigator.pop(context, _QueueAction(_QueueKind.adopt, sel)),
          icon: const Icon(Icons.check, size: 16),
          label: Text(widget.remaining > 1 ? '採用して次へ' : '採用'),
        ),
      ],
    );
  }
}
