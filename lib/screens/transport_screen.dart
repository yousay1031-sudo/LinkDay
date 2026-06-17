import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/customer.dart';
import '../models/transport_plan.dart';
import '../services/customer_service.dart';
import '../services/settings_service.dart';
import '../services/transport_pdf_service.dart';
import '../services/transport_plan_service.dart';
import '../services/weekly_schedule_service.dart';
import '../theme/app_theme.dart';
import 'transport_map_screen.dart';

/// 送迎計画画面
class TransportScreen extends StatefulWidget {
  const TransportScreen({super.key});

  @override
  State<TransportScreen> createState() => _TransportScreenState();
}

class _TransportScreenState extends State<TransportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;
  String? _errorMessage;

  // 現在表示中のルート
  List<TransportVehicleRoute> _pickupRoutes = [];
  List<TransportVehicleRoute> _dropoffRoutes = [];

  // 設定
  String _facilityAddress = 'ココスタディ';
  String? _restApiKey; // REST API キー（Geocoding/Directions用）

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadSettings();
    _loadRoutes();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _dateKey {
    final d = _selectedDate;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadSettings() async {
    final settings = SettingsService.instance.getSettings();
    final key = await SettingsService.instance.loadRestApiKey();
    if (mounted) {
      setState(() {
        _facilityAddress = settings.facilityAddress;
        _restApiKey = key;
      });
    }
  }

  Future<void> _loadRoutes() async {
    setState(() => _isLoading = true);
    try {
      final pickup = TransportPlanService.instance.getPickupRoutes(_dateKey);
      final dropoff = TransportPlanService.instance.getDropoffRoutes(_dateKey);
      if (mounted) {
        setState(() {
          _pickupRoutes = pickup;
          _dropoffRoutes = dropoff;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '読み込みエラー: $e';
        });
      }
    }
  }

  /// その日の利用予定者を取得する（週間計画 → regularDays フォールバック）
  List<Customer> _getScheduledCustomers() {
    final dayOfWeek = _selectedDate.weekday; // 1=月〜7=日
    final allActive = CustomerService.instance.getAllCustomers();

    // 週間利用計画から対象者を取得
    final fromSchedule = allActive.where((c) {
      final entries =
          WeeklyScheduleService.instance.getEntriesForDate(_selectedDate);
      // entries は ScheduleEntry リスト（顧客IDを持つ）
      return entries.any((e) =>
          e.customerId == c.id &&
          e.status.name != 'cancelled'); // cancelled 以外
    }).toList();

    if (fromSchedule.isNotEmpty) return fromSchedule;

    // フォールバック: regularDays
    if (dayOfWeek >= 1 && dayOfWeek <= 6) {
      return allActive
          .where((c) => c.regularDays.contains(dayOfWeek))
          .toList();
    }
    return [];
  }

  // ── 自動グループ分け ────────────────────────────────────────

  Future<void> _autoGroup(TransportType type) async {
    final customers = _getScheduledCustomers();
    if (customers.isEmpty) {
      _showSnack('利用予定者がいません', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final routes = await TransportPlanService.instance.autoGroupCustomers(
        dateKey: _dateKey,
        customers: customers,
        type: type,
        apiKey: _restApiKey,
      );

      // 保存
      for (final r in routes) {
        await TransportPlanService.instance.saveRoute(r);
      }

      await _loadRoutes();
      _showSnack(
        '${type == TransportType.pickup ? 'お迎え' : 'お送り'}を自動グループ分けしました（${customers.length}名 → ${routes.length}台）',
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('グループ分けエラー: $e', isError: true);
    }
  }

  // ── ルート最適化 ────────────────────────────────────────────

  Future<void> _optimizeRoute(TransportVehicleRoute route) async {
    if (_restApiKey == null || _restApiKey!.isEmpty) {
      _showSnack('APIキーが設定されていません。設定画面で登録してください。', isError: true);
      return;
    }
    if (route.stops.isEmpty) {
      _showSnack('停留所がありません', isError: true);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await TransportPlanService.instance.optimizeRoute(
        route,
        _facilityAddress,
        _restApiKey!,
      );
      await _loadRoutes();
      _showSnack('${route.vehicleName} のルートを最適化しました');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('最適化エラー: $e', isError: true);
    }
  }

  // ── Google Maps を開く ──────────────────────────────────────

  Future<void> _openGoogleMaps(TransportVehicleRoute route) async {
    String? url = route.googleMapsUrl;
    if (url == null || url.isEmpty) {
      if (route.stops.isEmpty) {
        _showSnack('停留所がありません', isError: true);
        return;
      }
      url = _buildGoogleMapsUrl(route);
    }
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        _showSnack('Google マップを開けませんでした', isError: true);
      }
    } catch (e) {
      _showSnack('URL エラー: $e', isError: true);
    }
  }

  String _buildGoogleMapsUrl(TransportVehicleRoute route) {
    final addresses = route.stops.map((s) => s.address).toList();
    if (addresses.isEmpty) return '';

    if (route.transportType == TransportType.pickup) {
      final origin = Uri.encodeComponent(addresses.first);
      final dest = Uri.encodeComponent(_facilityAddress);
      final wps = addresses.length > 1
          ? addresses.sublist(1).map(Uri.encodeComponent).join('/')
          : '';
      return 'https://www.google.com/maps/dir/$origin/${wps.isNotEmpty ? '$wps/' : ''}$dest?travelmode=driving';
    } else {
      final origin = Uri.encodeComponent(_facilityAddress);
      final dest = Uri.encodeComponent(addresses.last);
      final wps = addresses.length > 1
          ? addresses.sublist(0, addresses.length - 1).map(Uri.encodeComponent).join('/')
          : '';
      return 'https://www.google.com/maps/dir/$origin/${wps.isNotEmpty ? '$wps/' : ''}$dest?travelmode=driving';
    }
  }

  // ── PDF 出力 ────────────────────────────────────────────────

  Future<void> _printPdf() async {
    final all = TransportPlanService.instance.getRoutesByDate(_dateKey);
    if (all.isEmpty) {
      _showSnack('ルートデータがありません', isError: true);
      return;
    }
    try {
      await TransportPdfService.instance.printTransportSheet(_dateKey, all);
    } catch (e) {
      _showSnack('PDF エラー: $e', isError: true);
    }
  }

  // ── ルート削除 ──────────────────────────────────────────────

  Future<void> _deleteRoute(TransportVehicleRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルートを削除'),
        content: Text('${route.vehicleName}（${route.typeLabel}）を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await TransportPlanService.instance.deleteRoute(
        route.dateKey,
        route.vehicleIndex,
        route.transportType,
      );
      await _loadRoutes();
      _showSnack('${route.vehicleName} を削除しました');
    }
  }

  // ── 停留所並び替え ──────────────────────────────────────────

  Future<void> _reorderStop(
      TransportVehicleRoute route, int oldIndex, int newIndex) async {
    final stops = List<TransportStop>.from(route.stops);
    if (newIndex > oldIndex) newIndex -= 1;
    final item = stops.removeAt(oldIndex);
    stops.insert(newIndex, item);
    for (int i = 0; i < stops.length; i++) {
      stops[i].orderIndex = i;
    }
    route.stops
      ..clear()
      ..addAll(stops);
    await TransportPlanService.instance.saveRoute(route);
    await _loadRoutes();
  }

  // ── 停留所削除 ──────────────────────────────────────────────

  Future<void> _removeStop(TransportVehicleRoute route, int stopIndex) async {
    final stops = List<TransportStop>.from(route.stops)
      ..removeAt(stopIndex);
    for (int i = 0; i < stops.length; i++) {
      stops[i].orderIndex = i;
    }
    route.stops
      ..clear()
      ..addAll(stops);
    await TransportPlanService.instance.saveRoute(route);
    await _loadRoutes();
  }

  // ── 地図画面を開く ──────────────────────────────────────────

  void _openMap(TransportVehicleRoute route) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TransportMapScreen(
          route: route,
          facilityAddress: _facilityAddress,
        ),
      ),
    ).then((_) => _loadRoutes());
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? AppColors.error : AppColors.success,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  // ────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildDateNav(),
          _buildTabBar(),
          if (_isLoading)
            const LinearProgressIndicator(
              minHeight: 3,
              color: AppColors.primary,
            ),
          if (_errorMessage != null)
            _buildErrorBanner(),
          Expanded(child: _buildTabView()),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text('送迎計画'),
      actions: [
        IconButton(
          icon: const Icon(Icons.picture_as_pdf),
          tooltip: 'PDF出力',
          onPressed: _printPdf,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // ── 日付ナビゲーション ───────────────────────────────────────

  Widget _buildDateNav() {
    final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = weekdays[_selectedDate.weekday - 1];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                _selectedDate =
                    _selectedDate.subtract(const Duration(days: 1));
              });
              _loadRoutes();
            },
          ),
          GestureDetector(
            onTap: () => _pickDate(),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    '${_selectedDate.year}年${_selectedDate.month}月${_selectedDate.day}日（$wd）',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                _selectedDate = _selectedDate.add(const Duration(days: 1));
              });
              _loadRoutes();
            },
          ),
          // 今日ボタン
          TextButton(
            onPressed: () {
              setState(() => _selectedDate = DateTime.now());
              _loadRoutes();
            },
            child: const Text('今日',
                style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('ja'),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
      _loadRoutes();
    }
  }

  // ── タブ ─────────────────────────────────────────────────────

  Widget _buildTabBar() {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        labelColor: AppColors.primary,
        unselectedLabelColor: AppColors.onSurfaceVariant,
        indicatorColor: AppColors.primary,
        tabs: [
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_downward, size: 18),
                const SizedBox(width: 6),
                Text(
                  'お迎え（${_pickupRoutes.fold(0, (s, r) => s + r.stops.length)}名）',
                ),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_upward, size: 18),
                const SizedBox(width: 6),
                Text(
                  'お送り（${_dropoffRoutes.fold(0, (s, r) => s + r.stops.length)}名）',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabView() {
    return TabBarView(
      controller: _tabController,
      children: [
        _buildRouteTab(TransportType.pickup, _pickupRoutes),
        _buildRouteTab(TransportType.dropoff, _dropoffRoutes),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      color: AppColors.error.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ── ルートタブ本体 ───────────────────────────────────────────

  Widget _buildRouteTab(
      TransportType type, List<TransportVehicleRoute> routes) {
    final label = type == TransportType.pickup ? 'お迎え' : 'お送り';
    return CustomScrollView(
      slivers: [
        // 自動グループ分けボタンバー
        SliverToBoxAdapter(child: _buildActionBar(type, routes)),
        if (routes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(label),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _buildRouteCard(routes[i]),
              childCount: routes.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Widget _buildActionBar(
      TransportType type, List<TransportVehicleRoute> routes) {
    final scheduledCount = _getScheduledCustomers().length;
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Text(
            '利用予定 $scheduledCount 名',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _isLoading ? null : () => _autoGroup(type),
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('自動グループ分け'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
            ),
          ),
          const SizedBox(width: 8),
          if (routes.isNotEmpty)
            OutlinedButton.icon(
              onPressed: _isLoading ? null : () => _optimizeAllRoutes(routes),
              icon: const Icon(Icons.route, size: 18),
              label: const Text('全最適化'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.secondary,
                side: const BorderSide(color: AppColors.secondary),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _optimizeAllRoutes(
      List<TransportVehicleRoute> routes) async {
    if (_restApiKey == null || _restApiKey!.isEmpty) {
      _showSnack('APIキーが設定されていません', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    try {
      for (final r in routes) {
        if (r.stops.isNotEmpty) {
          await TransportPlanService.instance
              .optimizeRoute(r, _facilityAddress, _restApiKey!);
        }
      }
      await _loadRoutes();
      _showSnack('全ルートを最適化しました');
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('最適化エラー: $e', isError: true);
    }
  }

  Widget _buildEmptyState(String label) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.directions_car_outlined,
              size: 64,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('$label ルートがありません',
              style: const TextStyle(
                  color: AppColors.onSurfaceVariant, fontSize: 15)),
          const SizedBox(height: 8),
          const Text('「自動グループ分け」で作成してください',
              style:
                  TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13)),
        ],
      ),
    );
  }

  // ── 車両カード ───────────────────────────────────────────────

  Widget _buildRouteCard(TransportVehicleRoute route) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius)),
      elevation: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRouteCardHeader(route),
          if (route.stops.isNotEmpty) _buildStopsList(route),
          _buildRouteCardFooter(route),
        ],
      ),
    );
  }

  Widget _buildRouteCardHeader(TransportVehicleRoute route) {
    final isFull = route.isFull;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppTheme.cardBorderRadius)),
      ),
      child: Row(
        children: [
          // 車両アイコン
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.directions_car,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      route.vehicleName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildCapacityBadge(route),
                    if (isFull) ...[
                      const SizedBox(width: 6),
                      _buildBadge('満員', AppColors.error),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (route.totalDistanceLabel != '—') ...[
                      const Icon(Icons.straighten, size: 13,
                          color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(route.totalDistanceLabel,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceVariant)),
                      const SizedBox(width: 10),
                    ],
                    if (route.totalDurationLabel != '—') ...[
                      const Icon(Icons.timer_outlined, size: 13,
                          color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(route.totalDurationLabel,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceVariant)),
                    ],
                    if (route.optimizedAt != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle, size: 13,
                          color: AppColors.success),
                      const SizedBox(width: 3),
                      const Text('最適化済',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.success)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // アクションメニュー
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.onSurfaceVariant),
            onSelected: (v) => _onCardMenuSelected(v, route),
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'optimize',
                  child: Row(children: [
                    Icon(Icons.route, size: 18),
                    SizedBox(width: 8),
                    Text('ルート最適化'),
                  ])),
              const PopupMenuItem(
                  value: 'map',
                  child: Row(children: [
                    Icon(Icons.map, size: 18),
                    SizedBox(width: 8),
                    Text('地図を見る'),
                  ])),
              const PopupMenuItem(
                  value: 'gmaps',
                  child: Row(children: [
                    Icon(Icons.open_in_new, size: 18),
                    SizedBox(width: 8),
                    Text('Google マップで開く'),
                  ])),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 18, color: AppColors.error),
                    SizedBox(width: 8),
                    Text('削除', style: TextStyle(color: AppColors.error)),
                  ])),
            ],
          ),
        ],
      ),
    );
  }

  void _onCardMenuSelected(String value, TransportVehicleRoute route) {
    switch (value) {
      case 'optimize':
        _optimizeRoute(route);
        break;
      case 'map':
        _openMap(route);
        break;
      case 'gmaps':
        _openGoogleMaps(route);
        break;
      case 'delete':
        _deleteRoute(route);
        break;
    }
  }

  Widget _buildCapacityBadge(TransportVehicleRoute route) {
    return _buildBadge(
      '${route.passengerCount}/${route.capacity}名',
      route.isFull ? AppColors.error : AppColors.secondary,
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ── 停留所リスト（並び替え可能）───────────────────────────────

  Widget _buildStopsList(TransportVehicleRoute route) {
    return Column(
      children: [
        // 出発地（お迎え: 最初の利用者宅、お送り: 事業所）
        _buildFacilityTile(
          route.transportType == TransportType.pickup ? null : _facilityAddress,
          isStart: true,
          type: route.transportType,
        ),
        // 並び替え可能な停留所リスト
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: route.stops.length,
          onReorder: (oldIndex, newIndex) =>
              _reorderStop(route, oldIndex, newIndex),
          itemBuilder: (ctx, i) {
            final stop = route.stops[i];
            return _buildStopTile(stop, i, route);
          },
        ),
        // 到着地（お迎え: 事業所、お送り: 最後の利用者宅）
        _buildFacilityTile(
          route.transportType == TransportType.dropoff ? null : _facilityAddress,
          isStart: false,
          type: route.transportType,
        ),
      ],
    );
  }

  Widget _buildFacilityTile(String? address,
      {required bool isStart, required TransportType type}) {
    final isPickup = type == TransportType.pickup;
    // お迎え: 開始=不定(最初の利用者宅)、終了=事業所
    // お送り: 開始=事業所、終了=不定(最後の利用者宅)
    final isFacility = (isPickup && !isStart) || (!isPickup && isStart);
    if (!isFacility) return const SizedBox.shrink();

    return ListTile(
      leading: const SizedBox(
        width: 32,
        height: 32,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Icon(Icons.home, color: Colors.white, size: 18),
        ),
      ),
      title: const Text(
        '事業所',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Text(
        _facilityAddress,
        style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
        overflow: TextOverflow.ellipsis,
      ),
      dense: true,
    );
  }

  Widget _buildStopTile(
      TransportStop stop, int index, TransportVehicleRoute route) {
    return ListTile(
      key: ValueKey('${route.id}_stop_$index'),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.4)),
        ),
        child: Center(
          child: Text(
            '${index + 1}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.secondary,
            ),
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              stop.customerName,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (stop.durationLabel.isNotEmpty)
            Text(
              stop.durationLabel,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
        ],
      ),
      subtitle: Text(
        stop.address.isNotEmpty ? stop.address : '住所未登録',
        style: TextStyle(
          fontSize: 11,
          color: stop.address.isNotEmpty
              ? AppColors.onSurfaceVariant
              : AppColors.error,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stop.distanceLabel.isNotEmpty)
            Text(
              stop.distanceLabel,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.onSurfaceVariant),
            ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppColors.error),
            onPressed: () => _removeStop(route, index),
            tooltip: '除外',
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const Icon(Icons.drag_handle,
              size: 20, color: AppColors.onSurfaceVariant),
        ],
      ),
      dense: true,
    );
  }

  // ── カードフッター ───────────────────────────────────────────

  Widget _buildRouteCardFooter(TransportVehicleRoute route) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          // ルート最適化
          _footerButton(
            icon: Icons.route,
            label: '最適化',
            onTap: () => _optimizeRoute(route),
            color: AppColors.secondary,
          ),
          const SizedBox(width: 8),
          // 地図表示
          _footerButton(
            icon: Icons.map_outlined,
            label: '地図',
            onTap: () => _openMap(route),
            color: AppColors.success,
          ),
          const SizedBox(width: 8),
          // Googleマップ
          _footerButton(
            icon: Icons.open_in_new,
            label: 'G-Maps',
            onTap: () => _openGoogleMaps(route),
            color: AppColors.info,
          ),
          const Spacer(),
          if (route.optimizedAt != null)
            Text(
              '最適化: ${_formatDateTime(route.optimizedAt!)}',
              style: const TextStyle(
                  fontSize: 10, color: AppColors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _footerButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
