import 'dart:async';

// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;

import '../data/data_session.dart';
import '../data/staff_session.dart';
import '../theme/app_theme.dart';
import 'staff_picker.dart';

/// 画面上部に「いまの担当者」を常に表示する帯。
///
/// MaterialApp.builder から全画面の上に置く（画面ごとの修正を不要にするため）。
/// ログイン後（DataSession が ready）のときだけ表示する。
/// 帯は Navigator の外にあるため、ダイアログは [navigatorKey] の文脈で開く。
class StaffBarScope extends StatelessWidget {
  const StaffBarScope({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DataSession.instance,
      builder: (context, _) {
        if (!DataSession.instance.isReady) return child;
        // 【描画順に注意】Navigator 内の BlockSemantics は「先に描かれた兄弟」の
        // セマンティクスを捨てるため、帯を Navigator より先に描くと読み上げ・
        // 操作補助から帯が消える。VerticalDirection.up で「Navigator を先に描き、
        // 帯は画面上部・後から描く」ようにし、読み上げ順は sortKey で帯を先にする。
        return Column(
          verticalDirection: VerticalDirection.up,
          children: [
            Expanded(
              child: Semantics(
                sortKey: const OrdinalSortKey(1),
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: child,
                ),
              ),
            ),
            Semantics(
              container: true,
              sortKey: const OrdinalSortKey(0),
              child: StaffBar(navigatorKey: navigatorKey),
            ),
          ],
        );
      },
    );
  }
}

class StaffBar extends StatefulWidget {
  const StaffBar({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<StaffBar> createState() => _StaffBarState();
}

class _StaffBarState extends State<StaffBar> {
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    _armMidnight();
  }

  /// 開いたまま 0 時をまたいだら担当者を未選択に戻す（前日の担当者のまま記録しない）
  void _armMidnight() {
    _midnight?.cancel();
    final now = StaffSession.instance.clock();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      StaffSession.instance.checkDay();
      if (mounted) _armMidnight();
    });
  }

  @override
  void dispose() {
    _midnight?.cancel();
    super.dispose();
  }

  GlobalKey<NavigatorState> get navigatorKey => widget.navigatorKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: StaffSession.instance,
      builder: (context, _) {
        final staff = StaffSession.instance.current;
        final selected = staff != null;
        final bg = selected ? const Color(0xFFFFF3E0) : AppColors.warning;
        final fg = selected ? AppColors.onSurface : Colors.black;
        void open() {
          final ctx = navigatorKey.currentContext;
          if (ctx != null) showStaffPicker(ctx);
        }

        return Material(
          color: bg,
          child: SafeArea(
            bottom: false,
            // 読み上げ・操作補助では帯全体を 1 つのボタンとして扱い、タップ動作も
            // そのノードに持たせる（excludeSemantics で InkWell の動作が消えるため）
            child: Semantics(
              button: true,
              label: selected
                  ? '担当者 ${staff.name}。タップして変更'
                  : '担当者が選ばれていません。タップして選択',
              onTap: open,
              excludeSemantics: true,
              child: InkWell(
                key: const Key('staffBar'),
                onTap: open,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                          selected
                              ? Icons.badge_outlined
                              : Icons.warning_amber_rounded,
                          size: 18,
                          color: fg),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          selected
                              ? '担当：${staff.name}'
                              : '担当者が選ばれていません（タップして選択）',
                          key: const Key('staffBarLabel'),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: fg,
                          ),
                        ),
                      ),
                      Text(selected ? '変更' : '選択',
                          style: TextStyle(
                              fontSize: 13,
                              color: fg,
                              decoration: TextDecoration.underline)),
                      Icon(Icons.arrow_drop_down, color: fg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
