import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/customer.dart';
import '../models/geocode_candidate.dart';
import '../services/transport_location_resolver.dart';
import '../theme/app_theme.dart';
import 'draggable_marker_map.dart';

// ════════════════════════════════════════════════════════════════
// 送迎場所 解決状態チップ
// ════════════════════════════════════════════════════════════════

class TransportLocationStatusChip extends StatelessWidget {
  final String status;
  final ({double lat, double lng})? coord;
  final bool compact;

  const TransportLocationStatusChip({
    super.key,
    required this.status,
    this.coord,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status) {
      Customer.locResolved => ('自動採用', AppColors.success.withValues(alpha: 0.75), Icons.auto_awesome),
      Customer.locManual => ('手動採用', AppColors.success, Icons.check_circle),
      Customer.locFailed => ('取得失敗', AppColors.error, Icons.error_outline),
      _ => ('未解決', AppColors.onSurfaceVariant, Icons.help_outline),
    };
    final outside = coord != null &&
        GeocodeCandidate(formattedAddress: '', lat: coord!.lat, lng: coord!.lng)
            .isOutsideObihiroBounds;
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 10 : 12, color: color),
              const SizedBox(width: 3),
              Text(label,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: compact ? 9.5 : 10.5,
                      color: color,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (outside)
          Container(
            padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
            ),
            child: Text('帯広市外の可能性',
                softWrap: false,
                style: TextStyle(
                    fontSize: compact ? 9.5 : 10.5,
                    color: AppColors.warning,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 候補選択ボトムシート
// ════════════════════════════════════════════════════════════════

/// 候補一覧 → 選択 → 「この地点を採用」。戻り値は採用候補（キャンセルは null）
///
/// [blockReasonText] が渡されると「自動採用不可（要確認）」バナーを表示する。
/// [query] が渡され、表示文字列と異なる場合は補完後クエリを表示する。
Future<GeocodeCandidate?> showGeocodeCandidateSheet(
  BuildContext context, {
  required String address,
  required List<GeocodeCandidate> candidates,
  String? title,
  bool autoAdopted = false,
  String? blockReasonText,
  String? query,
}) {
  return showModalBottomSheet<GeocodeCandidate>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _CandidateSheet(
      address: address,
      candidates: candidates,
      title: title,
      autoAdopted: autoAdopted,
      blockReasonText: blockReasonText,
      query: query,
    ),
  );
}

class _CandidateSheet extends StatefulWidget {
  final String address;
  final List<GeocodeCandidate> candidates;
  final String? title;
  final bool autoAdopted;
  final String? blockReasonText;
  final String? query;
  const _CandidateSheet({
    required this.address,
    required this.candidates,
    this.title,
    required this.autoAdopted,
    this.blockReasonText,
    this.query,
  });

  @override
  State<_CandidateSheet> createState() => _CandidateSheetState();
}

class _CandidateSheetState extends State<_CandidateSheet> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final cands = widget.candidates;
    final sel = cands.isNotEmpty ? cands[_selected.clamp(0, cands.length - 1)] : null;
    final maxH = MediaQuery.of(context).size.height * 0.88;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.place_outlined, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title ?? '候補から選択',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      Text('「${widget.address}」 ${cands.length} 件',
                          style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant)),
                      if (widget.query != null && widget.query != widget.address)
                        Text('検索クエリ: 「${widget.query}」',
                            style: const TextStyle(
                                fontSize: 10.5, color: AppColors.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (widget.autoAdopted)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('自動採用済み',
                        style: TextStyle(fontSize: 10.5, color: AppColors.success,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
          if (widget.blockReasonText != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.warning),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '自動採用不可（要確認）: ${widget.blockReasonText}。'
                      '帯広市内の正しい地点を選んで採用してください。',
                      style: const TextStyle(fontSize: 11, color: AppColors.warning),
                    ),
                  ),
                ],
              ),
            ),
          if (cands.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('候補がありません', style: TextStyle(color: AppColors.onSurfaceVariant)),
            )
          else ...[
            // 候補リスト
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: cands.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (_, i) {
                  final c = cands[i];
                  final isSel = i == _selected;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selected = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSel ? AppColors.primary.withValues(alpha: 0.08) : null,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: isSel ? AppColors.primary : AppColors.divider,
                            width: isSel ? 1.5 : 1),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(isSel ? Icons.radio_button_checked : Icons.radio_button_off,
                              size: 18, color: isSel ? AppColors.primary : AppColors.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.formattedAddress,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 2,
                                  children: [
                                    _miniChip(c.typeLabel, AppColors.info),
                                    if (c.partialMatch) _miniChip('部分一致', AppColors.warning),
                                    if (c.isOutsideObihiroBounds)
                                      _miniChip('帯広市外の可能性', AppColors.warning),
                                    if (c.isCountryLevel)
                                      _miniChip('国レベル（採用不可）', AppColors.error)
                                    else if (!c.hasPointGranularity)
                                      _miniChip('粒度不足', AppColors.warning),
                                    _miniChip(
                                        '${c.lat.toStringAsFixed(5)}, ${c.lng.toStringAsFixed(5)}',
                                        AppColors.onSurfaceVariant),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            // ミニ地図（選択中候補）
            if (sel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SizedBox(
                  height: 170,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: GoogleMap(
                      key: ValueKey('cand_${sel.lat}_${sel.lng}'),
                      initialCameraPosition: CameraPosition(
                          target: LatLng(sel.lat, sel.lng), zoom: 15),
                      markers: {
                        for (int i = 0; i < cands.length; i++)
                          Marker(
                            markerId: MarkerId('cand_$i'),
                            position: LatLng(cands[i].lat, cands[i].lng),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                                i == _selected
                                    ? BitmapDescriptor.hueOrange
                                    : BitmapDescriptor.hueAzure),
                            infoWindow: InfoWindow(title: cands[i].formattedAddress),
                          ),
                      },
                      zoomControlsEnabled: false,
                      myLocationButtonEnabled: false,
                      mapToolbarEnabled: false,
                      liteModeEnabled: false,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('キャンセル'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      // 「日本」等国レベル座標はどの経路でも保存させない
                      onPressed: (sel == null || sel.isCountryLevel)
                          ? null
                          : () => Navigator.pop(context, sel),
                      icon: const Icon(Icons.check),
                      label: Text(sel != null && sel.isCountryLevel
                          ? '国レベルは採用不可'
                          : 'この地点を採用'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniChip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );
}

// ════════════════════════════════════════════════════════════════
// 地図で微調整ダイアログ（DraggableMarkerMap 再利用）
// ════════════════════════════════════════════════════════════════

/// ドラッグで座標を微調整。戻り値は確定座標（キャンセルは null）
Future<LatLng?> showAdjustCoordDialog(
  BuildContext context, {
  required LatLng initial,
  required String title,
  String? snippet,
}) {
  LatLng current = initial;
  return showDialog<LatLng>(
    context: context,
    builder: (ctx) => AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      title: Row(
        children: [
          const Icon(Icons.edit_location_alt_outlined, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: DraggableMarkerMap(
            initialPosition: initial,
            markerTitle: title,
            markerSnippet: snippet,
            hue: BitmapDescriptor.hueGreen,
            height: 240,
            onPositionChanged: (p) => current = p,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, current),
          icon: const Icon(Icons.check),
          label: const Text('この位置を採用'),
        ),
      ],
    ),
  );
}

// ════════════════════════════════════════════════════════════════
// 地図から直接ピン指定ダイアログ（Day 8 追加改修 / 最終手段）
// ════════════════════════════════════════════════════════════════

/// 「地図から直接指定」の結果
class PinPickResult {
  final double lat;
  final double lng;

  /// 逆ジオコーディングで取得した住所（失敗時は null）
  final String? formattedAddress;

  const PinPickResult({
    required this.lat,
    required this.lng,
    this.formattedAddress,
  });
}

/// 地図をタップ / マーカーをドラッグしてピンを立てる（geocode 0 件でも使える最終手段）
///
/// [initial] は TransportLocationResolver.resolveInitialPinPosition() の結果を渡す。
/// 確定時に [reverseGeocode] で住所取得を試み、失敗しても座標のみで確定できる。
Future<PinPickResult?> showMapPinPickerDialog(
  BuildContext context, {
  required MapPinInitial initial,
  required String title,
  String? addressLabel,
  Future<String?> Function(double lat, double lng)? reverseGeocode,
}) {
  return showDialog<PinPickResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MapPinPickerDialog(
      initial: initial,
      title: title,
      addressLabel: addressLabel,
      reverseGeocode: reverseGeocode,
    ),
  );
}

class _MapPinPickerDialog extends StatefulWidget {
  final MapPinInitial initial;
  final String title;
  final String? addressLabel;
  final Future<String?> Function(double lat, double lng)? reverseGeocode;

  const _MapPinPickerDialog({
    required this.initial,
    required this.title,
    this.addressLabel,
    this.reverseGeocode,
  });

  @override
  State<_MapPinPickerDialog> createState() => _MapPinPickerDialogState();
}

class _MapPinPickerDialogState extends State<_MapPinPickerDialog> {
  late LatLng _pos;
  GoogleMapController? _controller;
  bool _placed = false; // ユーザーが一度でもピンを動かした/置いたか
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pos = LatLng(widget.initial.lat, widget.initial.lng);
    debugPrint('[MapPinPicker] open: ${widget.title} → ${widget.initial}');
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _setPos(LatLng p, String how) {
    setState(() {
      _pos = p;
      _placed = true;
    });
    debugPrint('[MapPinPicker] $how: '
        '${p.latitude.toStringAsFixed(7)}, ${p.longitude.toStringAsFixed(7)}');
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    String? addr;
    if (widget.reverseGeocode != null) {
      try {
        addr = await widget.reverseGeocode!(_pos.latitude, _pos.longitude);
      } catch (e) {
        // 逆ジオコード失敗は保存を妨げない（座標が本体）
        debugPrint('[MapPinPicker] reverseGeocode 失敗（座標のみ確定します）: $e');
        addr = null;
      }
    }
    if (!mounted) return;
    Navigator.pop(
        context,
        PinPickResult(
            lat: _pos.latitude, lng: _pos.longitude, formattedAddress: addr));
  }

  @override
  Widget build(BuildContext context) {
    final outside = GeocodeCandidate(
            formattedAddress: '', lat: _pos.latitude, lng: _pos.longitude)
        .isOutsideObihiroBounds;

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: Row(
        children: [
          const Icon(Icons.add_location_alt_outlined, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: const TextStyle(fontSize: 15)),
                if (widget.addressLabel != null)
                  Text('「${widget.addressLabel}」',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 操作ガイド + 初期位置の根拠
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.touch_app_outlined,
                        size: 15, color: AppColors.primary),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '地図をタップするとピンが移動します。'
                        'ピンをドラッグしても調整できます。\n'
                        '初期表示: ${widget.initial.sourceDescription}',
                        style: const TextStyle(fontSize: 11, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // 座標表示
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.my_location, size: 15, color: AppColors.success),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '緯度: ${_pos.latitude.toStringAsFixed(7)}   '
                        '経度: ${_pos.longitude.toStringAsFixed(7)}',
                        style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                      ),
                    ),
                    if (_placed)
                      const Icon(Icons.check_circle, size: 14, color: AppColors.success),
                  ],
                ),
              ),
              if (outside) ...[
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Icon(Icons.info_outline, size: 13, color: AppColors.warning),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text('帯広エリア外の位置です（近隣町村への送迎は採用できます）',
                          style: TextStyle(fontSize: 10.5, color: AppColors.warning)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  height: 300,
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                        target: LatLng(widget.initial.lat, widget.initial.lng),
                        zoom: widget.initial.zoom),
                    markers: {
                      Marker(
                        markerId: const MarkerId('pin_picker'),
                        position: _pos,
                        draggable: true,
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueOrange),
                        infoWindow: InfoWindow(
                            title: widget.title, snippet: widget.addressLabel),
                        onDragEnd: (p) => _setPos(p, 'drag'),
                      ),
                    },
                    onMapCreated: (c) => _controller = c,
                    // 地図タップでピンを移動（ドロップ操作）
                    onTap: (p) => _setPos(p, 'tap'),
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: true,
                    mapToolbarEnabled: false,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _confirm,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.push_pin, size: 16),
          label: Text(_busy ? '住所を取得中...' : 'この位置に決定'),
        ),
      ],
    );
  }
}
