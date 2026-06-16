import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/transport_plan.dart';
import '../services/google_maps_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// 送迎ルート地図表示画面
///
/// google_maps_flutter を使って停留所をマーカー＆ポリラインで表示。
/// Web プラットフォームでは google_maps_flutter_web が自動選択される。
class TransportMapScreen extends StatefulWidget {
  final TransportVehicleRoute route;
  final String facilityAddress;

  const TransportMapScreen({
    super.key,
    required this.route,
    required this.facilityAddress,
  });

  @override
  State<TransportMapScreen> createState() => _TransportMapScreenState();
}

class _TransportMapScreenState extends State<TransportMapScreen> {
  GoogleMapController? _mapController;
  bool _isLoading = true;
  String? _errorMessage;

  // 事業所の座標（Geocoding キャッシュから）
  LatLng? _facilityLatLng;

  // マーカーとポリライン
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // ルートのポリライン点（Directions API から取得）
  List<LatLng> _routePolylinePoints = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      // 事業所座標を取得（Hive キャッシュ優先）
      final settings = SettingsService.instance.getSettings();
      if (settings.facilityLat != null && settings.facilityLng != null) {
        _facilityLatLng = LatLng(settings.facilityLat!, settings.facilityLng!);
      } else {
        // キャッシュなし → 北海道帯広市のデフォルト座標
        _facilityLatLng = const LatLng(42.924, 143.196);
      }

      // マーカー構築
      _buildMarkers();

      // Directions API でポリライン取得（LatLng がある場合）
      await _fetchPolyline();

      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[TransportMapScreen] initialize error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '地図の初期化に失敗しました: $e';
        });
      }
    }
  }

  void _buildMarkers() {
    _markers.clear();

    // 事業所マーカー（オレンジ、homeアイコン的な star）
    if (_facilityLatLng != null) {
      _markers.add(
        Marker(
          markerId: const MarkerId('facility'),
          position: _facilityLatLng!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(
            title: 'ココスタディ',
            snippet: widget.facilityAddress,
          ),
        ),
      );
    }

    // 停留所マーカー（番号付き、青）
    for (int i = 0; i < widget.route.stops.length; i++) {
      final stop = widget.route.stops[i];
      if (stop.lat == null || stop.lng == null) continue;

      _markers.add(
        Marker(
          markerId: MarkerId('stop_$i'),
          position: LatLng(stop.lat!, stop.lng!),
          icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(
            title: '${i + 1}. ${stop.customerName}',
            snippet: stop.address,
          ),
        ),
      );
    }
  }

  Future<void> _fetchPolyline() async {
    final apiKey = await SettingsService.instance.loadApiKey();
    final allHaveGeocode = widget.route.stops.every(
      (s) => s.lat != null && s.lng != null,
    );

    if (!allHaveGeocode || apiKey == null || apiKey.isEmpty) {
      // LatLng だけでシンプルなポリライン（直線）を描く
      _buildSimplePolyline();
      return;
    }

    try {
      final stopAddresses = widget.route.stops.map((s) => s.address).toList();
      final String origin, destination;
      final List<String> waypoints;

      if (widget.route.transportType == TransportType.pickup) {
        origin = stopAddresses.first;
        destination = widget.facilityAddress;
        waypoints =
            stopAddresses.length > 1 ? stopAddresses.sublist(1) : [];
      } else {
        origin = widget.facilityAddress;
        destination = stopAddresses.last;
        waypoints = stopAddresses.length > 1
            ? stopAddresses.sublist(0, stopAddresses.length - 1)
            : [];
      }

      final result = await GoogleMapsService.instance.getDirections(
        origin: origin,
        destination: destination,
        waypoints: waypoints,
        apiKey: apiKey,
      );

      _routePolylinePoints = result.polylinePoints
          .map((p) => LatLng(p.lat, p.lng))
          .toList();

      _polylines.add(
        Polyline(
          polylineId: const PolylineId('route'),
          points: _routePolylinePoints,
          color: AppColors.primary,
          width: 4,
          patterns: const [],
        ),
      );
    } catch (e) {
      debugPrint('[TransportMapScreen] directions failed: $e');
      // フォールバック: 直線ポリライン
      _buildSimplePolyline();
    }
  }

  /// Directions API が使えない場合のシンプルなポリライン（事業所↔停留所を直線接続）
  void _buildSimplePolyline() {
    final points = <LatLng>[];

    if (widget.route.transportType == TransportType.pickup) {
      // お迎え: 各停留所 → 事業所
      for (final s in widget.route.stops) {
        if (s.lat != null && s.lng != null) {
          points.add(LatLng(s.lat!, s.lng!));
        }
      }
      if (_facilityLatLng != null) points.add(_facilityLatLng!);
    } else {
      // お送り: 事業所 → 各停留所
      if (_facilityLatLng != null) points.add(_facilityLatLng!);
      for (final s in widget.route.stops) {
        if (s.lat != null && s.lng != null) {
          points.add(LatLng(s.lat!, s.lng!));
        }
      }
    }

    if (points.length >= 2) {
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('route_simple'),
          points: points,
          color: AppColors.secondary,
          width: 3,
          patterns: [
            PatternItem.dash(20),
            PatternItem.gap(10),
          ],
        ),
      );
    }
  }

  /// 全マーカーが見えるようにカメラを調整
  void _fitBounds() {
    if (_mapController == null) return;

    final allPoints = <LatLng>[];
    if (_facilityLatLng != null) allPoints.add(_facilityLatLng!);
    for (final s in widget.route.stops) {
      if (s.lat != null && s.lng != null) {
        allPoints.add(LatLng(s.lat!, s.lng!));
      }
    }
    if (allPoints.isEmpty) return;

    if (allPoints.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(allPoints.first, 14),
      );
      return;
    }

    double minLat = allPoints.first.latitude;
    double maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude;
    double maxLng = allPoints.first.longitude;

    for (final p in allPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - 0.005, minLng - 0.005),
          northeast: LatLng(maxLat + 0.005, maxLng + 0.005),
        ),
        60,
      ),
    );
  }

  /// 初期カメラ位置
  LatLng get _initialCameraTarget {
    if (widget.route.stops.isNotEmpty) {
      final firstWithGeo =
          widget.route.stops.firstWhere(
        (s) => s.lat != null && s.lng != null,
        orElse: () => widget.route.stops.first,
      );
      if (firstWithGeo.lat != null && firstWithGeo.lng != null) {
        return LatLng(firstWithGeo.lat!, firstWithGeo.lng!);
      }
    }
    return _facilityLatLng ?? const LatLng(42.924, 143.196);
  }

  Future<void> _openGoogleMaps() async {
    final url = widget.route.googleMapsUrl ??
        _buildFallbackGoogleMapsUrl();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google マップ URL を生成できませんでした')),
      );
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _buildFallbackGoogleMapsUrl() {
    if (widget.route.stops.isEmpty) return '';
    final addresses = widget.route.stops.map((s) => s.address).toList();
    if (widget.route.transportType == TransportType.pickup) {
      final parts = [
        ...addresses,
        widget.facilityAddress,
      ].map(Uri.encodeComponent).join('/');
      return 'https://www.google.com/maps/dir/$parts?travelmode=driving';
    } else {
      final parts = [
        widget.facilityAddress,
        ...addresses,
      ].map(Uri.encodeComponent).join('/');
      return 'https://www.google.com/maps/dir/$parts?travelmode=driving';
    }
  }

  // ────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.route.vehicleName} - ${widget.route.typeLabel}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Google マップで開く',
            onPressed: _openGoogleMaps,
          ),
          IconButton(
            icon: const Icon(Icons.fit_screen),
            tooltip: '全体を表示',
            onPressed: _fitBounds,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── 地図本体 ──────────────────────────────────────────
          if (_errorMessage != null)
            _buildErrorState()
          else
            _buildMap(),

          // ── 左パネル: 停留所リスト ────────────────────────────
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: _buildStopPanel(),
          ),

          // ── ローディング ─────────────────────────────────────
          if (_isLoading)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.white54,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: _initialCameraTarget,
        zoom: 12,
      ),
      markers: _markers,
      polylines: _polylines,
      mapType: MapType.normal,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: true,
      onMapCreated: (controller) {
        _mapController = controller;
        // 少し待ってからバウンド調整
        Future.delayed(const Duration(milliseconds: 500), _fitBounds);
      },
      // Web での gesture 競合を防ぐ
      gestureRecognizers: kIsWeb
          ? {
              Factory<OneSequenceGestureRecognizer>(
                () => EagerGestureRecognizer(),
              ),
            }
          : {},
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.map_outlined,
                size: 64, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error),
            ),
            const SizedBox(height: 16),
            const Text(
              'Google Maps API キーが設定されているか確認してください。\n'
              'APIキーがなくても停留所リストは確認できます。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: AppColors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ── 左パネル: 停留所サマリー ─────────────────────────────────

  Widget _buildStopPanel() {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー
          Container(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            color: AppColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.route.typeLabel,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500),
                ),
                Text(
                  widget.route.vehicleName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.people, size: 13, color: Colors.white70),
                    const SizedBox(width: 4),
                    Text(
                      '${widget.route.passengerCount}名',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(width: 10),
                    if (widget.route.totalDistanceLabel != '—') ...[
                      const Icon(Icons.straighten,
                          size: 13, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text(
                        widget.route.totalDistanceLabel,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // 停留所リスト
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _stopItems.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 12),
              itemBuilder: (ctx, i) => _stopItems[i],
            ),
          ),

          // Google マップ URL ボタン
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openGoogleMaps,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('ドライバー用マップ'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 停留所リストのアイテム（事業所 + 各利用者）
  List<Widget> get _stopItems {
    final items = <Widget>[];
    final isPickup = widget.route.transportType == TransportType.pickup;

    // お送り: 事業所を先頭に
    if (!isPickup) {
      items.add(_facilityItem);
    }

    for (int i = 0; i < widget.route.stops.length; i++) {
      final s = widget.route.stops[i];
      items.add(ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: AppColors.secondary.withValues(alpha: 0.15),
          child: Text(
            '${i + 1}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.secondary),
          ),
        ),
        title: Text(
          s.customerName,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          s.address.isNotEmpty ? s.address : '住所未登録',
          style: const TextStyle(fontSize: 10),
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          if (s.lat != null && s.lng != null) {
            _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(LatLng(s.lat!, s.lng!), 15),
            );
          }
        },
      ));
    }

    // お迎え: 事業所を末尾に
    if (isPickup) {
      items.add(_facilityItem);
    }

    return items;
  }

  Widget get _facilityItem => ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: AppColors.primary.withValues(alpha: 0.15),
          child: const Icon(Icons.home, size: 16, color: AppColors.primary),
        ),
        title: const Text(
          'ココスタディ',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          widget.facilityAddress,
          style: const TextStyle(fontSize: 10),
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          if (_facilityLatLng != null) {
            _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(_facilityLatLng!, 14),
            );
          }
        },
      );
}
