import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/customer.dart';
import '../models/geocode_candidate.dart';
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
Future<GeocodeCandidate?> showGeocodeCandidateSheet(
  BuildContext context, {
  required String address,
  required List<GeocodeCandidate> candidates,
  String? title,
  bool autoAdopted = false,
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
    ),
  );
}

class _CandidateSheet extends StatefulWidget {
  final String address;
  final List<GeocodeCandidate> candidates;
  final String? title;
  final bool autoAdopted;
  const _CandidateSheet({
    required this.address,
    required this.candidates,
    this.title,
    required this.autoAdopted,
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
                      onPressed: sel == null ? null : () => Navigator.pop(context, sel),
                      icon: const Icon(Icons.check),
                      label: const Text('この地点を採用'),
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
