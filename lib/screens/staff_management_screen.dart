// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../data/account_session.dart';
import '../models/staff.dart';
import '../services/login_history_service.dart';
import '../services/staff_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion/app_buttons.dart';
import '../widgets/motion/empty_state.dart';
import 'inactive_staff_screen.dart';
import 'login_history_screen.dart';
import 'staff_edit_screen.dart';

/// 職員管理: 在籍中の職員の一覧。
///
/// 一覧の作りは顧客管理と同じ（幅に応じて 1〜4 列、1 件の高さも同じ詰め方）。
/// 在籍終了の職員は別の画面（右上のボタン）に分ける。
/// 職員の登録は管理者だけ（管理者でなければ理由を出し、登録ボタンは出さない）。
class StaffManagementScreen extends StatelessWidget {
  const StaffManagementScreen({super.key});

  static int columnCount(double width) {
    if (width >= 1280) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  /// 1 件の高さ（顧客管理と同じ。1 列: 横並び、複数列: 縦並び）
  static double cardExtent(int cols) => cols == 1 ? 84 : 128;

  static const double _gridSpacing = 10;

  void _openEdit(BuildContext context, [Staff? s]) {
    Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => StaffEditScreen(staff: s)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        StaffService.instance,
        AccountSession.instance,
        LoginHistoryService.instance,
      ]),
      builder: (context, _) {
        final admin = AccountSession.instance.isAdmin;
        final reason = AccountSession.instance.adminOnlyReason;
        final list = StaffService.instance.getActiveStaff();
        return Scaffold(
          appBar: AppBar(
            title: const Text('職員管理'),
            actions: [
              // ログイン履歴は管理者だけが読める（ルールでも同じ）
              if (admin)
                IconButton(
                  key: const Key('openLoginHistory'),
                  icon: const Icon(Icons.history),
                  tooltip: 'ログイン履歴',
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LoginHistoryScreen()),
                  ),
                ),
              IconButton(
                key: const Key('openInactiveStaff'),
                icon: const Icon(Icons.inventory_2_outlined),
                tooltip: '在籍終了の職員',
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const InactiveStaffScreen()),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (reason != null)
                Container(
                  key: const Key('staffListAdminNote'),
                  width: double.infinity,
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline,
                          size: 18, color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '職員の登録・在籍終了・ログインの設定は管理者だけができます。$reason',
                          style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyState(
                        icon: Icons.badge_outlined,
                        title: '在籍中の職員はいません',
                        message: '管理者が「職員を登録」から追加できます',
                      )
                    : LayoutBuilder(builder: (context, c) {
                        final cols = columnCount(c.maxWidth);
                        return GridView.builder(
                          key: const Key('staffList'),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            crossAxisSpacing: _gridSpacing,
                            mainAxisSpacing: _gridSpacing,
                            mainAxisExtent: cardExtent(cols),
                          ),
                          itemCount: list.length,
                          itemBuilder: (context, i) => _StaffCard(
                            staff: list[i],
                            // 最後にログインした日時（ログイン履歴は管理者だけが読める）
                            lastLogin: admin
                                ? LoginHistoryService.instance
                                    .lastLoginOf(list[i].id)
                                : null,
                            horizontal: cols == 1,
                            onTap: () => _openEdit(context, list[i]),
                          ),
                        );
                      }),
              ),
            ],
          ),
          floatingActionButton: admin
              ? AppExtendedFab(
                  key: const Key('staffAddFab'),
                  onPressed: () => _openEdit(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('職員を登録'),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                )
              : null,
        );
      },
    );
  }
}

/// 一覧の 1 件
class _StaffCard extends StatelessWidget {
  const _StaffCard({
    required this.staff,
    required this.lastLogin,
    required this.horizontal,
    required this.onTap,
  });

  final Staff staff;
  final DateTime? lastLogin;
  final bool horizontal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = staff;
    final last = lastLogin;
    final sub = [
      if (s.role != null) s.role!.label,
      if (s.workDays.isNotEmpty) '勤務 ${s.workDaysLabel}',
    ].join('　');
    // 最終ログインは役割・勤務日とは別に出す（同じ行だと、役割の名前が長いと切れて
    // 見えなくなるため）。複数列は独立した 1 行、1 列は氏名の行の右。
    final lastText = last == null
        ? null
        : Text(
            '最終ログイン ${DateFormat('M/d HH:mm').format(last)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 11, color: AppColors.onSurfaceVariant),
          );
    final name = Text(
      s.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: AppColors.onSurface),
    );
    final subText = Text(
      sub.isEmpty ? '役割・勤務日は未設定' : sub,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
    );
    final badges = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _LoginBadge(status: s.loginStatus),
        if (s.canDrive) const _Badge(label: '送迎可', color: AppColors.secondary),
        if (s.isAdmin) const _Badge(label: '管理者', color: AppColors.primary),
      ],
    );
    return Card(
      key: Key('staffCard_${s.id}'),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: horizontal
              ? Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor:
                          AppColors.primary.withValues(alpha: 0.15),
                      child: Text(s.name.isNotEmpty ? s.name[0] : '?',
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        // 1 列（狭い幅）は高さが低いので、最終ログインは氏名の行の右に置く
                        children: [
                          Row(children: [
                            Flexible(child: name),
                            if (lastText != null) ...[
                              const SizedBox(width: 8),
                              lastText,
                            ],
                          ]),
                          subText,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 札は右に縦に並べる（顧客管理の横並びのカードと同じ置き方）
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _LoginBadge(status: s.loginStatus),
                        if (s.canDrive || s.isAdmin) const SizedBox(height: 4),
                        if (s.canDrive || s.isAdmin)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            if (s.isAdmin)
                              const _Badge(
                                  label: '管理者', color: AppColors.primary),
                            if (s.isAdmin && s.canDrive)
                              const SizedBox(width: 4),
                            if (s.canDrive)
                              const _Badge(
                                  label: '送迎可', color: AppColors.secondary),
                          ]),
                      ],
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right,
                        color: AppColors.onSurfaceVariant, size: 20),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    name,
                    const SizedBox(height: 2),
                    Text(s.kana,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    subText,
                    if (lastText != null) lastText,
                    const Spacer(),
                    badges,
                  ],
                ),
        ),
      ),
    );
  }
}

class _LoginBadge extends StatelessWidget {
  const _LoginBadge({required this.status});
  final StaffLoginStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      StaffLoginStatus.allowed => AppColors.secondary,
      StaffLoginStatus.stopped => AppColors.error,
      StaffLoginStatus.none => AppColors.onSurfaceVariant,
    };
    return _Badge(label: 'ログイン：${status.label}', color: color);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
