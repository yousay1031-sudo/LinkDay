import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/attendance_service.dart';
import '../services/monthly_usage_service.dart';
import '../services/auth_service.dart';
import '../services/customer_service.dart';
import '../theme/app_theme.dart';
import 'attendance_screen.dart';
import 'customer_management_screen.dart';
import 'settings_screen.dart';
import 'transport_screen.dart';
import 'weekly_schedule_screen.dart';

/// メニュー項目データクラス
class _MenuItem {
  final String title;
  final IconData icon;
  final Color color;
  final String route;

  const _MenuItem({
    required this.title,
    required this.icon,
    required this.color,
    required this.route,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _expiringCount = 0;
  int _attendanceUnprocessedCount = 0;

  /// Day 9: 支給超過見込みの児童（残が少ない順）
  List<MonthlyUsage> _overProjected = [];

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  void _loadCounts() {
    final expiring = CustomerService.instance.getExpiringCertCustomers();
    final unprocessed =
        AttendanceService.instance.getUnprocessedCount(DateTime.now());
    debugPrint('[HomeScreen] _loadCounts: expiring=${expiring.length}, '
        'unprocessed=$unprocessed');
    if (!mounted) return;
    setState(() {
      _expiringCount = expiring.length;
      _attendanceUnprocessedCount = unprocessed;
    });
    // Day 9: 支給超過見込みは非同期集計（同じ _loadCounts 系列に乗せる）
    _loadOverProjected();
  }

  /// 支給超過見込みの児童を集計する（Day 9）
  Future<void> _loadOverProjected() async {
    final over =
        await MonthlyUsageService.instance.getOverProjected(DateTime.now());
    debugPrint('[HomeScreen] _loadCounts: overProjected=${over.length}');
    if (!mounted) return;
    setState(() => _overProjected = over);
  }

  /// メニュー一覧
  static const List<_MenuItem> _menuItems = [
    _MenuItem(
      title: '顧客管理',
      icon: Icons.people,
      color: Color(0xFF1976D2),
      route: '/customers',
    ),
    _MenuItem(
      title: '週間利用計画',
      icon: Icons.calendar_view_week,
      color: Color(0xFF388E3C),
      route: '/weekly-plan',
    ),
    _MenuItem(
      title: '翌日予約選択',
      icon: Icons.event_available,
      color: Color(0xFF7B1FA2),
      route: '/next-day-booking',
    ),
    _MenuItem(
      title: '送迎計画',
      icon: Icons.directions_car,
      color: Color(0xFFF57C00),
      route: '/transport',
    ),
    _MenuItem(
      title: '出席管理',
      icon: Icons.check_circle,
      color: Color(0xFF00838F),
      route: '/attendance',
    ),
    _MenuItem(
      title: '業務日誌',
      icon: Icons.description,
      color: Color(0xFF5D4037),
      route: '/daily-journal',
    ),
    _MenuItem(
      title: '個別支援計画',
      icon: Icons.assignment,
      color: Color(0xFFC62828),
      route: '/support-plan',
    ),
    _MenuItem(
      title: '職員管理',
      icon: Icons.badge,
      color: Color(0xFF37474F),
      route: '/staff',
    ),
  ];

  /// 画面幅に応じたグリッド列数を返す
  int _getColumnCount(double width) {
    if (width >= 1280) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  void _onMenuTapped(BuildContext context, _MenuItem item) {
    // 顧客管理
    if (item.route == '/customers') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const CustomerManagementScreen(),
        ),
      ).then((_) => _loadCounts());
      return;
    }
    // 出席管理
    if (item.route == '/attendance') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const AttendanceScreen(),
        ),
      ).then((_) => _loadCounts());
      return;
    }
    // 週間利用計画
    if (item.route == '/weekly-plan') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const WeeklyScheduleScreen(),
        ),
      ).then((_) => _loadCounts());
      return;
    }
    // 送迎計画
    if (item.route == '/transport') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const TransportScreen(),
        ),
      ).then((_) => _loadCounts());
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(item.icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Text(
              '「${item.title}」は準備中です',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        backgroundColor: item.color,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // [開発専用] Service Worker キャッシュクリア
  // kDebugMode = true のビルド（flutter run / flutter build --debug）のみ表示。
  // --release ビルドでは完全に除去される。
  // ─────────────────────────────────────────────

  /// Web の Service Worker を全 unregister してページをリロードする
  void _onClearCache(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cleaning_services, color: AppColors.warning, size: 22),
            SizedBox(width: 8),
            Text('キャッシュクリア'),
          ],
        ),
        content: const Text(
          'Service Worker を unregister して\nページをリロードします。\n\n'  
          '（開発者向け機能 / DEBUG ビルドのみ）',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // unawaited: Future は即時開始し、完了を待たない
              // （ダイアログを閉じてから非同期処理を走らせる）
              _executeCacheClear(context); // ignore: discarded_futures
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
            ),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('クリア & リロード'),
          ),
        ],
      ),
    );
  }

  /// 実際のキャッシュクリア処理
  /// index.html の ?nocache=1 ハンドラと連携して SW を全 unregister する。
  /// Web 以外では SnackBar で案内するだけ。
  Future<void> _executeCacheClear(BuildContext context) async {
    if (!kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('キャッシュクリアは Web プラットフォームのみ対応しています'),
        ),
      );
      return;
    }

    // ?nocache=1 クエリ付き URL を構築
    // index.html 側で全 SW unregister → クリーンリロードを処理する
    final currentUri = Uri.base;
    final existingParams = Map<String, String>.from(currentUri.queryParameters)
      ..remove('nocache');
    final clearUri = currentUri.replace(
      queryParameters: {...existingParams, 'nocache': '1'},
    );
    debugPrint('[DevTool] キャッシュクリア → $clearUri');

    // SnackBar で通知
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 12),
              Text('Service Worker をクリアしてリロードします...'),
            ],
          ),
          backgroundColor: AppColors.warning,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    // url_launcher で ?nocache=1 付き URL に遷移
    // Flutter Web では launchUrl が現在タブで同一オリジン URL を開く
    await Future.delayed(const Duration(seconds: 1));
    if (!context.mounted) return;

    try {
      final launched = await launchUrl(
        clearUri,
        mode: LaunchMode.platformDefault,
      );
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '手動で以下の URL へ移動してください:\n${clearUri.toString()}',
              style: const TextStyle(fontSize: 12),
            ),
            backgroundColor: AppColors.secondary,
            duration: const Duration(seconds: 15),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[DevTool] キャッシュクリアエラー: $e');
    }
  }

  void _onLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.logout, color: AppColors.error, size: 22),
            SizedBox(width: 8),
            Text('ログアウト'),
          ],
        ),
        content: const Text(
          'ログアウトしますか？\nログイン画面に戻ります。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await AuthService.instance.signOut();
                // AuthGate の StreamBuilder が自動で LoginScreen に切り替えるため
                // Navigator による手動遷移は不要
              } on AuthException catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(e.message),
                    backgroundColor: AppColors.error,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context, _expiringCount),
      body: SafeArea(
        child: _buildBody(context),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
      BuildContext context, int expiringCount) {
    return AppBar(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.child_care,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Text('LinkDay'),
        ],
      ),
      actions: [
        // 施設名表示（将来実装用のプレースホルダー）
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              'サンプル施設',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 受給者証期限アラートバッジ
        if (expiringCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  tooltip: '受給者証期限アラート',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CustomerManagementScreen(),
                      ),
                    ).then((_) => _loadCounts());
                  },
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: AppColors.error,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        expiringCount > 9 ? '9+' : '$expiringCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 出席管理 未処理バッジ
        if (_attendanceUnprocessedCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_circle_outline),
                  tooltip: '出席未処理あり',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AttendanceScreen(),
                      ),
                    ).then((_) => _loadCounts());
                  },
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Color(0xFF2E7D32),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        _attendanceUnprocessedCount > 9
                            ? '9+'
                            : '$_attendanceUnprocessedCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── [DEBUG ONLY] キャッシュクリアボタン ──────────────────────
        // kDebugMode == true のビルドのみ表示
        // flutter build web --release では tree-shaking により完全除去される
        if (kDebugMode)
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: '[DEV] キャッシュクリア',
            onPressed: () => _onClearCache(context),
          ),

        // 設定アイコン
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '設定',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SettingsScreen(),
              ),
            ).then((_) => _loadCounts());
          },
        ),
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'ログアウト',
          onPressed: () => _onLogout(context),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = _getColumnCount(constraints.maxWidth);
        final padding = constraints.maxWidth >= 900 ? 24.0 : 16.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ヘッダーエリア
            _buildHeader(context),

            // Day 9: 支給超過見込みサマリー
            if (_overProjected.isNotEmpty)
              _buildOverProjectedCard(context, padding),

            // グリッドメニュー
            Expanded(
              child: GridView.builder(
                padding: EdgeInsets.all(padding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columnCount,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: columnCount == 1 ? 3.0 : 1.1,
                ),
                itemCount: _menuItems.length,
                itemBuilder: (context, index) {
                  return _buildMenuCard(context, _menuItems[index], columnCount);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// Day 9: 支給超過見込みサマリーカード（タップで顧客一覧へ）
  Widget _buildOverProjectedCard(BuildContext context, double padding) {
    final count = _overProjected.length;
    final names = _overProjected.take(3).map((u) => u.customerName).join('、');
    final more = count > 3 ? ' ほか${count - 3}名' : '';

    return Padding(
      padding: EdgeInsets.fromLTRB(padding, 0, padding, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CustomerManagementScreen()),
          ).then((_) => _loadCounts());
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.error.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.warning_amber_rounded,
                    color: AppColors.error, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('支給超過見込み $count 名',
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.error)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$names$more',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '今月の支給日数を超過する見込みです。超過分は利用者負担となる可能性があります',
                      style: TextStyle(fontSize: 10.5, color: AppColors.error),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final now = DateTime.now();
    final weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final weekday = weekdays[now.weekday - 1];
    final summary = AttendanceService.instance.getTodaySummary(now);
    final todayCount = summary.presentCount + summary.departedCount;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 今日の日付
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${now.year}年${now.month}月${now.day}日（$weekday）',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
              const Text(
                'ダッシュボード',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const Spacer(),
          // クイック情報（将来実装用プレースホルダー）
          _buildQuickStat(
            icon: Icons.people,
            label: '本日利用',
            value: '$todayCount名',
            color: AppColors.secondary,
          ),
          const SizedBox(width: 16),
          _buildQuickStat(
            icon: Icons.directions_car,
            label: '送迎待ち',
            value: '--件',
            color: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStat({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMenuCard(
    BuildContext context,
    _MenuItem item,
    int columnCount,
  ) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
      ),
      child: InkWell(
        onTap: () => _onMenuTapped(context, item),
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        splashColor: item.color.withValues(alpha: 0.1),
        highlightColor: item.color.withValues(alpha: 0.05),
        child: Padding(
          padding: columnCount == 1
              ? const EdgeInsets.symmetric(horizontal: 20, vertical: 16)
              : const EdgeInsets.all(16),
          child: columnCount == 1
              ? _buildCardContentHorizontal(item)
              : _buildCardContentVertical(item),
        ),
      ),
    );
  }

  Widget _buildCardContentVertical(_MenuItem item) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // アイコン背景
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: item.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            item.icon,
            size: 36,
            color: item.color,
          ),
        ),
        const SizedBox(height: 12),
        // タイトル
        Text(
          item.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.onSurface,
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Widget _buildCardContentHorizontal(_MenuItem item) {
    return Row(
      children: [
        // アイコン
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: item.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            item.icon,
            size: 32,
            color: item.color,
          ),
        ),
        const SizedBox(width: 16),
        // タイトル
        Expanded(
          child: Text(
            item.title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
        ),
        // 矢印
        Icon(
          Icons.chevron_right,
          color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ],
    );
  }
}
