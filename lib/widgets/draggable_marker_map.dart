import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../theme/app_theme.dart';

/// ドラッグ可能マーカー付き地図（事業所位置補正 / 送迎場所微調整で共用）
///
/// - 座標ヘッダー（緯度・経度・ヒント）
/// - GoogleMap（1 マーカー、draggable）
/// - [onPositionChanged] でドラッグ後の座標を通知
/// - 任意で下部にアクションボタン（[actionLabel] + [onAction]）
class DraggableMarkerMap extends StatefulWidget {
  final LatLng initialPosition;
  final String markerTitle;
  final String? markerSnippet;
  final double hue;
  final double height;
  final double zoom;
  final ValueChanged<LatLng>? onPositionChanged;

  /// 下部アクションボタン（null で非表示）
  final String? actionLabel;
  final IconData actionIcon;
  final bool actionBusy;
  final VoidCallback? onAction;

  /// 追加マーカー（候補一覧表示など。ドラッグ不可）
  final Set<Marker> extraMarkers;

  const DraggableMarkerMap({
    super.key,
    required this.initialPosition,
    required this.markerTitle,
    this.markerSnippet,
    this.hue = BitmapDescriptor.hueOrange,
    this.height = 260,
    this.zoom = 16,
    this.onPositionChanged,
    this.actionLabel,
    this.actionIcon = Icons.place,
    this.actionBusy = false,
    this.onAction,
    this.extraMarkers = const {},
  });

  @override
  State<DraggableMarkerMap> createState() => _DraggableMarkerMapState();
}

class _DraggableMarkerMapState extends State<DraggableMarkerMap> {
  late LatLng _pos;
  GoogleMapController? _controller;

  @override
  void initState() {
    super.initState();
    _pos = widget.initialPosition;
  }

  @override
  void didUpdateWidget(covariant DraggableMarkerMap old) {
    super.didUpdateWidget(old);
    if (old.initialPosition != widget.initialPosition) {
      _pos = widget.initialPosition;
      _controller?.animateCamera(CameraUpdate.newLatLng(_pos));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDragEnd(LatLng p) {
    setState(() => _pos = p);
    widget.onPositionChanged?.call(p);
    debugPrint('[DraggableMarkerMap] dragged: '
        '${p.latitude.toStringAsFixed(7)}, ${p.longitude.toStringAsFixed(7)}');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              topRight: Radius.circular(10),
            ),
            border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.my_location, size: 16, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('緯度: ${_pos.latitude.toStringAsFixed(7)}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.onSurface, fontFamily: 'monospace')),
                    Text('経度: ${_pos.longitude.toStringAsFixed(7)}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.onSurface, fontFamily: 'monospace')),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'マーカーをドラッグして\n位置を微調整できます',
                style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.right,
              ),
            ],
          ),
        ),
        ClipRRect(
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(10),
            bottomRight: Radius.circular(10),
          ),
          child: SizedBox(
            height: widget.height,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: widget.initialPosition, zoom: widget.zoom),
              markers: {
                Marker(
                  markerId: const MarkerId('draggable_marker'),
                  position: _pos,
                  draggable: true,
                  icon: BitmapDescriptor.defaultMarkerWithHue(widget.hue),
                  infoWindow: InfoWindow(title: widget.markerTitle, snippet: widget.markerSnippet),
                  onDragEnd: _onDragEnd,
                ),
                ...widget.extraMarkers,
              },
              onMapCreated: (c) => _controller = c,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
              mapToolbarEnabled: false,
            ),
          ),
        ),
        if (widget.actionLabel != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.actionBusy ? null : widget.onAction,
              icon: widget.actionBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(widget.actionIcon, size: 18),
              label: Text(widget.actionBusy ? '保存中...' : widget.actionLabel!,
                  style: const TextStyle(fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
