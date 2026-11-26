import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/customer.dart';
import '../verify/verify_config.dart';
import '../verify/verify_faults.dart';
import '../models/transport_load.dart';
import '../models/transport_plan.dart';
import '../models/weekly_schedule.dart';
import '../services/customer_service.dart';
import '../services/settings_service.dart';
import '../services/transport_pdf_service.dart';
import '../data/staff_session.dart';
import '../services/transport_plan_service.dart';
import '../services/weekly_schedule_service.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../utils/load_sequencer.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/motion/empty_state.dart';
import '../widgets/motion/press_scale.dart';
import '../widgets/motion/skeleton_gate.dart';
import '../widgets/motion/staggered.dart';
import '../widgets/motion/state_switcher.dart';
import '../widgets/motion/success_feedback.dart';
import '../widgets/skeletons/screen_skeletons.dart';
import 'settings_screen.dart';
import 'transport_map_screen.dart';

/// 送迎計画画面
class TransportScreen extends StatefulWidget {
  const TransportScreen({super.key, this.scheduledCustomersLoader});

  /// テスト用: 利用予定者の取得処理の差し替え（読込の保留・失敗の再現用）。
  /// 本番では常に null。
  @visibleForTesting
  final Future<List<Customer>> Function(DateTime date)?
      scheduledCustomersLoader;

  /// [date] の送迎の対象の児童（在籍中）。画面から切り出した（テストで直接呼ぶ）。
  ///
  /// 週間利用計画がある週は、その日の有効な予定（キャンセルを除く）だけ。0 件なら 0 人
  /// （全員をキャンセルにした日に、利用曜日から全員を対象にしない）。
  /// 週間利用計画が無い週だけ、利用曜日から。
  static Future<List<Customer>> scheduledCustomersFor(DateTime date) async {
    final allActive = CustomerService.instance.getAllCustomers();
    final dateLabel =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    // ── 優先度 1: 週間利用計画 ──────────────────────────────
    try {
      // 選んだ日の週を読み込んでから参照する（Firestore。読み込み済みの週だけを持つ）
      await WeeklyScheduleService.instance.ensureRange(date, date);
      final entries = WeeklyScheduleService.instance.getEntriesForDate(date);
      // planned + additional (cancelled 除外済み)

      // 週間利用計画がある週なら、その日の有効な予定だけを対象にする（0 件なら 0 人。
      // 全員をキャンセルにした日に、利用曜日から全員を対象にしないため）
      if (WeeklyScheduleService.instance.hasWeekFor(date)) {
        // ScheduleEntry.customerId → Customer に変換
        final result = <Customer>[];
        final idSet = <String>{};
        for (final entry in entries) {
          if (idSet.contains(entry.customerId)) continue;
          final customer =
              CustomerService.instance.getCustomerById(entry.customerId);
          if (customer != null && customer.isActive) {
            result.add(customer);
            idSet.add(entry.customerId);
          }
        }

        debugPrint('[TransportScreen] [$dateLabel] '
            'source=weekly_schedule, '
            'entries=${entries.length}, '
            'matched=${result.length}, '
            'ids=${result.map((c) => c.id).toList()}');

        return result;
      } else {
        debugPrint('[TransportScreen] [$dateLabel] '
            '週間計画が無い週。フォールバックへ。');
      }
    } catch (e) {
      debugPrint('[TransportScreen] [$dateLabel] '
          '週間計画取得エラー: $e。フォールバックへ。');
    }

    // ── 優先度 2: regularDays（曜日フォールバック）──────────
    final dayOfWeek = date.weekday; // 1=月〜7=日
    if (dayOfWeek >= 1 && dayOfWeek <= 6) {
      final result =
          allActive.where((c) => c.regularDays.contains(dayOfWeek)).toList();

      debugPrint('[TransportScreen] [$dateLabel] '
          'source=regular_days, '
          'weekday=$dayOfWeek, '
          'matched=${result.length}, '
          'ids=${result.map((c) => c.id).toList()}');

      if (result.isNotEmpty) return result;
    }

    // ── 優先度 3: アクティブ顧客全員（最終フォールバック）──
    debugPrint('[TransportScreen] [$dateLabel] '
        'source=all_active_customers (final fallback), '
        'count=${allActive.length}');
    return [];
  }

  @override
  State<TransportScreen> createState() => _TransportScreenState();
}

class _TransportScreenState extends State<TransportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;
  String? _errorMessage;

  /// 全データ読込（初回・日付変更）中。骨格表示用。
  /// 最適化・削除などの操作中（_isLoading）では立てない（画面を潰さない）
  bool _initialLoading = true;

  /// 全データ読込に失敗した（骨格ではなくエラー＋再試行を出す）
  bool _loadFailed = false;

  // 現在表示中のルート
  List<TransportVehicleRoute> _pickupRoutes = [];
  List<TransportVehicleRoute> _dropoffRoutes = [];

  // 利用予定者（週間計画 or regularDays から取得）
  List<Customer> _scheduledCustomers = [];

  // 設定
  String _facilityAddress = 'ここすたでぃ';
  String? _jsApiKey; // Google Maps API キー（JS Interop経由）

  @override
  void initState() {
    super.initState();
    debugPrint('[TransportScreen] initState start: '
        'initial selected date=$_dateKey');
    _tabController = TabController(length: 2, vsync: this);
    _loadSettings();
    _loadAll();
    TransportPlanService.instance.addListener(_onRoutesChanged);
    // 翌日予約選択・週間利用計画で「お休み」にしたら、停留所の表示を変える（ステップ4）
    WeeklyScheduleService.instance.addListener(_onScheduleChanged);
    debugPrint('[TransportScreen] initState end');
  }

  void _onScheduleChanged() {
    if (mounted) setState(() {});
  }

  /// 乗る人数に入れない児童（その日お休みの印が付いた児童）
  Set<String> _absentIds() => {
        for (final e in WeeklyScheduleService.instance
            .getAllEntriesForDate(_selectedDate))
          if (e.status == ScheduleStatus.cancelled) e.customerId
      };

  /// その日の予定がお休み（キャンセル）になっている児童か（表示だけ。ルートからは外さない）
  bool _isAbsent(String customerId) => WeeklyScheduleService.instance
      .getAllEntriesForDate(_selectedDate)
      .any((e) =>
          e.customerId == customerId && e.status == ScheduleStatus.cancelled);

  /// 他の端末（またはこの端末の別の画面）で送迎計画が変わった: 開き直さずに反映する
  void _onRoutesChanged() {
    if (!mounted || _initialLoading) return;
    _loadRoutes();
  }

  @override
  void dispose() {
    TransportPlanService.instance.removeListener(_onRoutesChanged);
    WeeklyScheduleService.instance.removeListener(_onScheduleChanged);
    _loadSeq.invalidate();
    _tabController.dispose();
    super.dispose();
  }

  String get _dateKey {
    final d = _selectedDate;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // ── 設定読み込み ─────────────────────────────────────────────

  Future<void> _loadSettings() async {
    final settings = SettingsService.instance.getSettings();
    final key = await SettingsService.instance.loadJsApiKey();
    if (mounted) {
      setState(() {
        _facilityAddress = settings.facilityAddress.isNotEmpty
            ? settings.facilityAddress
            : 'ここすたでぃ';
        _jsApiKey = key;
      });
    }
  }

  // ── 全データ読み込み ─────────────────────────────────────────

  /// 日付を素早く切り替えたとき、古い日付の読込結果で新しい日付を上書きしない
  final LoadSequencer _loadSeq = LoadSequencer();

  Future<void> _loadAll() async {
    final token = _loadSeq.begin();
    final dateKey = _dateKey;
    setState(() {
      _isLoading = true;
      _initialLoading = true;
      _loadFailed = false;
    });
    try {
      if (VerifyConfig.enabled) {
        await VerifyFaults.apply(VerifyFaults.transport);
      }
      // 利用予定者を取得（3段階フォールバック）
      final loader = widget.scheduledCustomersLoader;
      final customers = loader != null
          ? await loader(_selectedDate)
          : await _fetchScheduledCustomers();

      // 選んだ日の送迎計画（Firestore）を読み込んでから参照する
      await TransportPlanService.instance.ensureDate(dateKey);
      if (!mounted || !_loadSeq.isCurrent(token)) return;

      // ルートを取得
      final pickup = TransportPlanService.instance.getPickupRoutes(dateKey);
      final dropoff = TransportPlanService.instance.getDropoffRoutes(dateKey);

      debugPrint('[TransportScreen] _loadAll: customers=${customers.length}, '
          'pickupRoutes=${pickup.length}, dropoffRoutes=${dropoff.length}');
      if (mounted) {
        setState(() {
          _scheduledCustomers = customers;
          _pickupRoutes = pickup;
          _dropoffRoutes = dropoff;
          _isLoading = false;
          _initialLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted && _loadSeq.isCurrent(token)) {
        setState(() {
          _isLoading = false;
          _initialLoading = false;
          _loadFailed = true;
          _errorMessage = '読み込みエラー: $e';
        });
      }
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

  // ────────────────────────────────────────────────────────────
  // 利用予定者取得（3段階フォールバック）
  // ────────────────────────────────────────────────────────────

  /// 指定日の利用予定者を取得する
  ///
  /// 優先度 1: WeeklyScheduleService.getEntriesForDate（週間利用計画）
  /// 優先度 2: AttendanceService のスケジュール（未実装なら省略）
  /// 優先度 3: CustomerService の regularDays
  Future<List<Customer>> _fetchScheduledCustomers() =>
      TransportScreen.scheduledCustomersFor(_selectedDate);

  // ── 自動グループ分け ────────────────────────────────────────

  /// AppBar 用: 簡易グループ分け（APIキーなし）
  Future<void> _runAutoAssignSimple() async {
    await _runAutoAssign(useApi: false);
  }

  /// AppBar 用: AI実道路距離グループ分け
  Future<void> _runAutoAssignDistance() async {
    await _runAutoAssign(useApi: true);
  }

  /// お迎え・お送り両方を同時にグループ分け
  Future<void> _runAutoAssign({required bool useApi}) async {
    // 利用者を再取得（日付変更後に呼ばれる場合があるため）
    final customers = _scheduledCustomers.isNotEmpty
        ? _scheduledCustomers
        : await _fetchScheduledCustomers();

    if (customers.isEmpty) {
      _showSnack('利用予定者がいません', isError: true);
      return;
    }

    if (useApi && (_jsApiKey ?? '').isEmpty) {
      _showSnack('APIキーが設定されていません。設定画面で登録してください。', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final apiKey = useApi ? _jsApiKey : null;

      // お迎え・お送り両方生成
      final pickupRoutes =
          await TransportPlanService.instance.autoGroupCustomers(
        dateKey: _dateKey,
        customers: customers,
        type: TransportType.pickup,
        apiKey: apiKey,
      );
      final dropoffRoutes =
          await TransportPlanService.instance.autoGroupCustomers(
        dateKey: _dateKey,
        customers: customers,
        type: TransportType.dropoff,
        apiKey: apiKey,
      );

      // 保存
      for (final r in pickupRoutes) {
        await TransportPlanService.instance.saveRoute(r);
      }
      for (final r in dropoffRoutes) {
        await TransportPlanService.instance.saveRoute(r);
      }

      await _loadRoutes();
      final mode = useApi ? 'AI実道路' : '簡易';
      _showSnack(
        '[$mode] ${customers.length}名 → '
        'お迎え${pickupRoutes.length}台 / お送り${dropoffRoutes.length}台',
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('グループ分けエラー: $e', isError: true);
    }
  }

  /// タブ内アクションバー用（旧互換）
  Future<void> _autoGroup(TransportType type) async {
    final customers = _scheduledCustomers.isNotEmpty
        ? _scheduledCustomers
        : await _fetchScheduledCustomers();

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
        apiKey: _jsApiKey,
      );

      for (final r in routes) {
        await TransportPlanService.instance.saveRoute(r);
      }

      await _loadRoutes();
      _showSnack(
        '${type == TransportType.pickup ? 'お迎え' : 'お送り'}を自動グループ分けしました'
        '（${customers.length}名 → ${routes.length}台）',
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('グループ分けエラー: $e', isError: true);
    }
  }

  // ── ルート最適化 ────────────────────────────────────────────

  Future<void> _optimizeRoute(TransportVehicleRoute route) async {
    if ((_jsApiKey ?? '').isEmpty) {
      _showSnack('APIキーが設定されていません。設定画面で登録してください。', isError: true);
      return;
    }
    if (route.stops.isEmpty) {
      _showSnack('停留所がありません', isError: true);
      return;
    }

    // 最新の設定を再読込み（facilityLat/Lng の更新を反映）
    final latestSettings = SettingsService.instance.getSettings();
    final facilityLat = latestSettings.facilityLat;
    final facilityLng = latestSettings.facilityLng;
    final facilityAddress = latestSettings.facilityAddress.isNotEmpty
        ? latestSettings.facilityAddress
        : _facilityAddress;

    debugPrint('[TransportScreen] facilityLatLng='
        '${(facilityLat != null && facilityLng != null) ? "${facilityLat.toStringAsFixed(7)},${facilityLng.toStringAsFixed(7)}" : "null"}');

    // facilityLat/Lng 未設定の場合は警告して処理を続行（距離計算スキップ）
    if (facilityLat == null || facilityLng == null) {
      _showSnack(
        '事業所位置が未設定です。設定画面で住所確認後、位置を保存してください。',
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await TransportPlanService.instance.optimizeRoute(
        route,
        facilityAddress,
        // apiKey は内部で SettingsService から取得するため不要
      );
      await _loadRoutes();
      _showSnack('${route.vehicleName} のルートを最適化しました');
    } on DirectionsFallbackException catch (e) {
      // Directions API 失敗 → Haversine フォールバック適用済み
      // アプリは落ちていない。概算値で表示中である旨を通知する。
      await _loadRoutes();
      debugPrint('[TransportScreen] DirectionsFallback: ${e.message}');
      _showSnack(
        '⚠ ${e.message}',
        isError: false, // 警告（エラーではない）
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('最適化エラー: $e', isError: true);
    }
  }

  /// AppBar: 全ルート最適化（お迎え・お送り両方）
  Future<void> _optimizeAllRoutesAppBar() async {
    final allRoutes = [..._pickupRoutes, ..._dropoffRoutes];
    await _optimizeAllRoutes(allRoutes);
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
      return 'https://www.google.com/maps/dir/$origin/'
          '${wps.isNotEmpty ? '$wps/' : ''}$dest?travelmode=driving';
    } else {
      final origin = Uri.encodeComponent(_facilityAddress);
      final dest = Uri.encodeComponent(addresses.last);
      final wps = addresses.length > 1
          ? addresses
              .sublist(0, addresses.length - 1)
              .map(Uri.encodeComponent)
              .join('/')
          : '';
      return 'https://www.google.com/maps/dir/$origin/'
          '${wps.isNotEmpty ? '$wps/' : ''}$dest?travelmode=driving';
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
      await TransportPdfService.instance
          .printTransportSheet(_dateKey, all, absentIds: _absentIds());
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
          AppElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await TransportPlanService.instance.deleteRoute(
          route.dateKey,
          route.vehicleIndex,
          route.transportType,
        );
      } on StaffNotSelectedException {
        return; // 担当者の選択を閉じた → 削除しない
      }
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
    try {
      await TransportPlanService.instance.saveRoute(route);
    } on StaffNotSelectedException {
      // 担当者の選択を閉じた → 保存しない（ルートは保存先の内容に戻る）
    }
    await _loadRoutes();
  }

  // ── 停留所削除 ──────────────────────────────────────────────

  Future<void> _removeStop(TransportVehicleRoute route, int stopIndex) async {
    final stops = List<TransportStop>.from(route.stops)..removeAt(stopIndex);
    for (int i = 0; i < stops.length; i++) {
      stops[i].orderIndex = i;
    }
    route.stops
      ..clear()
      ..addAll(stops);
    try {
      await TransportPlanService.instance.saveRoute(route);
    } on StaffNotSelectedException {
      // 担当者の選択を閉じた → 保存しない（ルートは保存先の内容に戻る）
    }
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
    if (!isError) {
      // 成功はチェックマーク付き（文言は呼び出し元のまま）
      showSuccessSnack(context, msg);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.controlBorderRadius)),
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
          if (!_initialLoading) _buildShortageBanner(),
          _buildTabBar(),
          // 操作中（最適化・グループ分け等）の細い進行バー。初回読込は骨格が担当
          if (_isLoading && !_initialLoading)
            RefreshingBar(reduced: AppMotion.reduced(context)),
          if (_errorMessage != null && !_loadFailed) _buildErrorBanner(),
          _buildFacilityNotSetBanner(),
          Expanded(
            child: SkeletonGate(
              loading: _initialLoading,
              contentKey: _dateKey,
              errorMessage: _loadFailed ? _errorMessage : null,
              onRetry: _loadAll,
              skeleton: const TransportSkeleton(),
              builder: (context) => _buildTabView(),
            ),
          ),
        ],
      ),
    );
  }

  // ── AppBar ───────────────────────────────────────────────────

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text('送迎計画'),
      actions: [
        // 自動グループ分けポップアップ
        PopupMenuButton<String>(
          icon: const Icon(Icons.auto_awesome),
          tooltip: '自動グループ分け',
          onSelected: (mode) {
            if (mode == 'simple') {
              _runAutoAssignSimple();
            } else {
              _runAutoAssignDistance();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'simple',
              child: Row(children: [
                Icon(Icons.shuffle, size: 18),
                SizedBox(width: 8),
                Text('簡易（定員均等）'),
              ]),
            ),
            const PopupMenuItem(
              value: 'distance',
              child: Row(children: [
                Icon(Icons.route, size: 18),
                SizedBox(width: 8),
                Text('AI実道路距離'),
              ]),
            ),
          ],
        ),
        // ルート最適化（全件）
        IconButton(
          icon: const Icon(Icons.alt_route),
          tooltip: 'ルート最適化（全件）',
          onPressed: _isLoading ? null : _optimizeAllRoutesAppBar,
        ),
        // PDF出力
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
                _selectedDate = _selectedDate.subtract(const Duration(days: 1));
              });
              _loadAll();
            },
          ),
          PressableScale(
            child: GestureDetector(
              onTap: _pickDate,
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
                    // 日付の切替は StateSwitcher（0.7→1.0 / 250ms、消えない）
                    StateSwitcher(
                      stateKey: _dateKey,
                      child: Text(
                        '${_selectedDate.year}年${_selectedDate.month}月'
                        '${_selectedDate.day}日（$wd）',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                _selectedDate = _selectedDate.add(const Duration(days: 1));
              });
              _loadAll();
            },
          ),
          TextButton(
            onPressed: () {
              setState(() => _selectedDate = DateTime.now());
              _loadAll();
            },
            child: const Text('今日', style: TextStyle(color: AppColors.primary)),
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
      _loadAll();
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
                  'お迎え${_tabCount(_pickupRoutes)}',
                  key: const Key('transportTabPickup'),
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
                  'お送り${_tabCount(_dropoffRoutes)}',
                  key: const Key('transportTabDropoff'),
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
              _errorMessage ?? '',
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// 事業所位置未設定バナー
  Widget _buildFacilityNotSetBanner() {
    final settings = SettingsService.instance.getSettings();
    if (settings.hasGeocode) return const SizedBox.shrink();

    return Container(
      color: AppColors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.location_off, color: AppColors.warning, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '事業所の位置が未設定です。設定画面で住所を確認し、座標を取得・保存してください。',
              style: TextStyle(color: AppColors.warning, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.warning,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
            ),
            child: const Text('設定へ', style: TextStyle(fontSize: 12)),
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
        SliverToBoxAdapter(child: _buildActionBar(type, routes)),
        if (routes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(label),
          )
        else
          SliverToBoxAdapter(
            child: StaggerScope(
              child: Column(
                children: [
                  for (var i = 0; i < routes.length; i++)
                    StaggeredItem(
                      index: i,
                      total: routes.length,
                      child: _buildRouteCard(routes[i]),
                    ),
                ],
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  // ── アクションバー（タブ内）─────────────────────────────────

  Widget _buildActionBar(
      TransportType type, List<TransportVehicleRoute> routes) {
    final count = _scheduledCustomers.length;
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          // 利用予定者数バッジ
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: count > 0
                  ? AppColors.primary.withValues(alpha: 0.12)
                  : AppColors.onSurfaceVariant.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.people_outline,
                  size: 14,
                  color: count > 0
                      ? AppColors.primary
                      : AppColors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '利用予定 $count 名',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: count > 0
                        ? AppColors.primary
                        : AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // このタブのみ自動グループ分け
          AppOutlinedButton.icon(
            onPressed: _isLoading ? null : () => _autoGroup(type),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('自動グループ分け'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
          if (routes.isNotEmpty) ...[
            const SizedBox(width: 8),
            AppOutlinedButton.icon(
              onPressed: _isLoading ? null : () => _optimizeAllRoutes(routes),
              icon: const Icon(Icons.route, size: 16),
              label: const Text('全最適化'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.secondary,
                side: const BorderSide(color: AppColors.secondary),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _optimizeAllRoutes(List<TransportVehicleRoute> routes) async {
    if ((_jsApiKey ?? '').isEmpty) {
      _showSnack('APIキーが設定されていません', isError: true);
      return;
    }

    // 最新の設定を再読込み
    final latestSettings = SettingsService.instance.getSettings();
    final facilityLat = latestSettings.facilityLat;
    final facilityLng = latestSettings.facilityLng;
    final facilityAddress = latestSettings.facilityAddress.isNotEmpty
        ? latestSettings.facilityAddress
        : _facilityAddress;

    debugPrint('[TransportScreen] _optimizeAllRoutes facilityLatLng='
        '${(facilityLat != null && facilityLng != null) ? "${facilityLat.toStringAsFixed(7)},${facilityLng.toStringAsFixed(7)}" : "null"}');

    if (facilityLat == null || facilityLng == null) {
      _showSnack(
        '事業所位置が未設定です。設定画面で住所確認後、位置を保存してください。',
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);
    bool hasFallback = false;
    try {
      for (final r in routes) {
        if (r.stops.isNotEmpty) {
          try {
            await TransportPlanService.instance
                .optimizeRoute(r, facilityAddress);
          } on DirectionsFallbackException catch (e) {
            // 個別ルートで Directions 失敗 → フォールバック適用
            // 他のルートの処理は続行する
            hasFallback = true;
            debugPrint(
                '[TransportScreen] DirectionsFallback (${r.vehicleName}): ${e.message}');
          }
        }
      }
      await _loadRoutes();
      if (hasFallback) {
        _showSnack(
          '⚠ 一部ルートで経路計算に失敗しました。直線距離で概算表示しています。',
          isError: false,
        );
      } else {
        _showSnack('全ルートを最適化しました');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('最適化エラー: $e', isError: true);
    }
  }

  // ── 空状態UI（利用予定数 + 大ボタン）────────────────────────

  Widget _buildEmptyState(String label) {
    final count = _scheduledCustomers.length;
    final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = weekdays[_selectedDate.weekday - 1];
    final dateStr = '${_selectedDate.month}月${_selectedDate.day}日（$wd）';

    return EmptyState(
      icon: Icons.directions_car_outlined,
      title: '$label ルートがありません',
      message: count > 0 ? null : '$dateStrの週間計画にデータがありません\n週間利用計画を先に作成してください',
      actions: [
        if (count > 0) ...[
          // 利用予定数の表示
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTheme.pillBorderRadius),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people, size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  '$dateStrの利用予定: $count名',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // 自動グループ分け 大ボタン
          AppElevatedButton.icon(
            onPressed: _isLoading ? null : _showAutoAssignMenu,
            icon: const Icon(Icons.auto_awesome, size: 20),
            label: const Text(
              '自動グループ分け',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            ),
          ),
        ],
      ],
    );
  }

  /// 空状態の大ボタンから呼ぶ自動グループ分けメニュー
  void _showAutoAssignMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ハンドル
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '自動グループ分けモード',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${_scheduledCustomers.length}名をお迎え・お送り両方に割り当てます',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _autoAssignTile(
                icon: Icons.shuffle,
                title: '簡易（定員均等）',
                subtitle: 'APIキー不要。利用者を均等に振り分けます',
                color: AppColors.secondary,
                onTap: () {
                  Navigator.pop(ctx);
                  _runAutoAssignSimple();
                },
              ),
              const SizedBox(height: 8),
              _autoAssignTile(
                icon: Icons.route,
                title: 'AI実道路距離',
                subtitle: 'Google Maps APIを使って地理的に最適化します',
                color: AppColors.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _runAutoAssignDistance();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _autoAssignTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color),
          ],
        ),
      ),
    );
  }

  // ── 車両カード ───────────────────────────────────────────────

  Widget _buildRouteCard(TransportVehicleRoute route) {
    return PressableScale(
      child: _buildRouteCardBody(route),
    );
  }

  Widget _buildRouteCardBody(TransportVehicleRoute route) {
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
    final load = _loadOf(route);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppTheme.cardBorderRadius)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                const Icon(Icons.directions_car, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 狭い幅でもはみ出さないよう、入りきらない印は次の行へ
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        route.vehicleName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                    _buildCapacityBadge(route, load),
                    // 定員を超えているときは「満員」ではなく、超えた人数を強い色で出す
                    // お休みの児童がルートに残っていれば、その人数（乗る人数には入れない）
                    if (load.absent > 0)
                      KeyedSubtree(
                        key: ValueKey('${route.id}_absent'),
                        child: _buildBadge(
                            'お休み ${load.absent}名', AppColors.onSurfaceVariant),
                      ),
                    if (load.overLabel != null)
                      _buildStrongBadge(load.overLabel!,
                          key: ValueKey('${route.id}_over'))
                    else if (load.full)
                      _buildBadge('満員', AppColors.error),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (route.totalDistanceLabel != '—') ...[
                      const Icon(Icons.straighten,
                          size: 13, color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(route.totalDistanceLabel,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.onSurfaceVariant)),
                      const SizedBox(width: 10),
                    ],
                    if (route.totalDurationLabel != '—') ...[
                      const Icon(Icons.timer_outlined,
                          size: 13, color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(route.totalDurationLabel,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.onSurfaceVariant)),
                    ],
                    if (route.optimizedAt != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle,
                          size: 13, color: AppColors.success),
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
          PopupMenuButton<String>(
            icon:
                const Icon(Icons.more_vert, color: AppColors.onSurfaceVariant),
            onSelected: (v) => _onCardMenuSelected(v, route),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'optimize',
                  child: Row(children: [
                    Icon(Icons.route, size: 18),
                    SizedBox(width: 8),
                    Text('ルート最適化'),
                  ])),
              PopupMenuItem(
                  value: 'map',
                  child: Row(children: [
                    Icon(Icons.map, size: 18),
                    SizedBox(width: 8),
                    Text('地図を見る'),
                  ])),
              PopupMenuItem(
                  value: 'gmaps',
                  child: Row(children: [
                    Icon(Icons.open_in_new, size: 18),
                    SizedBox(width: 8),
                    Text('Google マップで開く'),
                  ])),
              PopupMenuDivider(),
              PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline,
                        size: 18, color: AppColors.error),
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
      case 'map':
        _openMap(route);
      case 'gmaps':
        _openGoogleMaps(route);
      case 'delete':
        _deleteRoute(route);
    }
  }

  /// 車の乗車状況（表示用）
  RouteLoad _loadOf(TransportVehicleRoute route) =>
      RouteLoad.of(route, absentIds: _absentIds());

  /// タブの人数: お休みを除いた人数と、含まれているお休みの人数
  String _tabCount(List<TransportVehicleRoute> routes) {
    final absent = _absentIds();
    final loads = [for (final r in routes) RouteLoad.of(r, absentIds: absent)];
    final riding = loads.fold(0, (s, l) => s + l.riding);
    final off = loads.fold(0, (s, l) => s + l.absent);
    return off > 0 ? '（$riding名・お休み$off）' : '（$riding名）';
  }

  Widget _buildCapacityBadge(TransportVehicleRoute route, RouteLoad load) {
    return KeyedSubtree(
      key: ValueKey('${route.id}_count'),
      child: _buildBadge(
        load.countLabel,
        load.over > 0 || load.full ? AppColors.error : AppColors.secondary,
      ),
    );
  }

  /// 強い色の印（赤地に白の太字）
  Widget _buildStrongBadge(String text, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.error,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.warning_amber_rounded, size: 13, color: Colors.white),
        const SizedBox(width: 3),
        Text(text,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ]),
    );
  }

  /// 車が足りない・定員を超えている車があるときの注意（画面の上）
  Widget _buildShortageBanner() {
    final notes = TransportShortage.notes([..._pickupRoutes, ..._dropoffRoutes],
        absentIds: _absentIds());
    if (notes.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('transportShortage'),
      width: double.infinity,
      color: AppColors.error,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notes.join('\n'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
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

  // ── 停留所リスト ─────────────────────────────────────────────

  Widget _buildStopsList(TransportVehicleRoute route) {
    return Column(
      children: [
        _buildFacilityTile(
          route.transportType == TransportType.pickup ? null : _facilityAddress,
          isStart: true,
          type: route.transportType,
        ),
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
        _buildFacilityTile(
          route.transportType == TransportType.dropoff
              ? null
              : _facilityAddress,
          isStart: false,
          type: route.transportType,
        ),
      ],
    );
  }

  Widget _buildFacilityTile(String? address,
      {required bool isStart, required TransportType type}) {
    final isPickup = type == TransportType.pickup;
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
          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.4)),
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          // お休みになった児童は分かるようにする（自動では外さない。外すときは「除外」）
          if (_isAbsent(stop.customerId))
            Container(
              key: ValueKey('${route.id}_stop_${index}_absent'),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('お休み',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppColors.error,
                      fontWeight: FontWeight.w700)),
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
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
          _footerButton(
            icon: Icons.route,
            label: '最適化',
            onTap: () => _optimizeRoute(route),
            color: AppColors.secondary,
          ),
          const SizedBox(width: 8),
          _footerButton(
            icon: Icons.map_outlined,
            label: '地図',
            onTap: () => _openMap(route),
            color: AppColors.success,
          ),
          const SizedBox(width: 8),
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
    return '${dt.month}/${dt.day} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
