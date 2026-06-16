import 'package:flutter/material.dart';
import '../models/attendance_record.dart';

/// ステータスに対応する色定義
class AttendanceColors {
  AttendanceColors._();

  static Color forStatus(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.scheduled:
        return const Color(0xFF1565C0); // 濃い青
      case AttendanceStatus.present:
        return const Color(0xFF2E7D32); // 濃い緑
      case AttendanceStatus.departed:
        return const Color(0xFF546E7A); // グレー
      case AttendanceStatus.absent:
        return const Color(0xFFC62828); // 濃い赤
    }
  }

  static Color backgroundForStatus(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.scheduled:
        return const Color(0xFFE3F2FD); // 薄い青
      case AttendanceStatus.present:
        return const Color(0xFFE8F5E9); // 薄い緑
      case AttendanceStatus.departed:
        return const Color(0xFFECEFF1); // 薄いグレー
      case AttendanceStatus.absent:
        return const Color(0xFFFFEBEE); // 薄い赤
    }
  }

  static IconData iconForStatus(AttendanceStatus status) {
    switch (status) {
      case AttendanceStatus.scheduled:
        return Icons.schedule;
      case AttendanceStatus.present:
        return Icons.login;
      case AttendanceStatus.departed:
        return Icons.logout;
      case AttendanceStatus.absent:
        return Icons.cancel_outlined;
    }
  }
}

/// ステータスバッジウィジェット
/// カード上部に小さなラベルとして表示する。
class AttendanceStatusBadge extends StatelessWidget {
  final AttendanceStatus status;
  final bool compact;

  const AttendanceStatusBadge({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = AttendanceColors.forStatus(status);
    final bg = AttendanceColors.backgroundForStatus(status);
    final icon = AttendanceColors.iconForStatus(status);
    final label = status.label;

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // present のときは緑の点を追加
          if (status == AttendanceStatus.present) ...[
            _PulseDot(color: color),
            const SizedBox(width: 5),
          ] else ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// present ステータス用の点滅する緑の点
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: _anim.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// AttendanceStatus の表示ラベル拡張
extension AttendanceStatusLabel on AttendanceStatus {
  String get label {
    switch (this) {
      case AttendanceStatus.scheduled:
        return '予定';
      case AttendanceStatus.present:
        return '在室中';
      case AttendanceStatus.departed:
        return '退室済';
      case AttendanceStatus.absent:
        return '欠席';
    }
  }
}
