// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/staff_session.dart';
import '../models/app_settings.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// 設定画面: 業務日誌「その日の内容」の選択肢（ステップ3）。
///
/// 足す・消す・並べ替えると、その場で保存する（担当者が必要）。
/// 消しても、過去の日誌にはそのとき選んだ名前が残る。
/// 入力中の「新しい選択肢」の欄だけは保存前の入力を持つ。他の端末で選択肢が
/// 変わっても、その欄は消さない（一覧はその場で新しい内容になる）。
class JournalActivityOptionsSection extends StatefulWidget {
  const JournalActivityOptionsSection({super.key});

  @override
  State<JournalActivityOptionsSection> createState() =>
      _JournalActivityOptionsSectionState();
}

class _JournalActivityOptionsSectionState
    extends State<JournalActivityOptionsSection> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<String> get _options =>
      SettingsService.instance.getSettings().journalActivityOptions;

  Future<bool> _save(List<String> next) async {
    try {
      await SettingsService.instance.updateJournalActivityOptions(next);
      return true;
    } on StaffNotSelectedException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('担当者を選ぶと保存できます'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return false;
    }
  }

  Future<void> _add() async {
    final v = _ctrl.text.trim();
    String? err;
    if (v.isEmpty) {
      err = '選択肢の名前を入れてください';
    } else if (v.length > AppSettings.maxJournalActivityLength) {
      err = '${AppSettings.maxJournalActivityLength}文字までにしてください';
    } else if (_options.contains(v)) {
      err = '「$v」はもうあります';
    } else if (_options.length >= AppSettings.maxJournalActivityCount) {
      err = '選択肢は${AppSettings.maxJournalActivityCount}個までです';
    }
    setState(() => _error = err);
    if (err != null) return;
    if (await _save([..._options, v])) {
      _ctrl.clear();
      if (mounted) setState(() {});
    }
  }

  Future<void> _remove(String v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「$v」を消しますか'),
        content: const Text('これからの日誌で選べなくなります。'
            '過去の日誌には、そのとき選んだ名前がそのまま残ります。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('やめる')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('消す')),
        ],
      ),
    );
    if (ok != true) return;
    await _save([..._options]..remove(v));
  }

  Future<void> _move(int i, int delta) async {
    final list = [..._options];
    final j = i + delta;
    if (j < 0 || j >= list.length) return;
    final v = list.removeAt(i);
    list.insert(j, v);
    await _save(list);
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '業務日誌の「その日の内容」で押して選ぶ選択肢です。足す・消す・並べ替えると、'
          'その場で保存します。消しても、過去の日誌にはそのとき選んだ名前が残ります。',
          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child:
                Text('選択肢がありません。下の欄から足してください。', style: TextStyle(fontSize: 13)),
          ),
        for (var i = 0; i < options.length; i++)
          SizedBox(
            key: Key('journalOption_${options[i]}'),
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(options[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14)),
                ),
                IconButton(
                  tooltip: '上へ',
                  icon: const Icon(Icons.arrow_upward, size: 20),
                  onPressed: i == 0 ? null : () => _move(i, -1),
                ),
                IconButton(
                  tooltip: '下へ',
                  icon: const Icon(Icons.arrow_downward, size: 20),
                  onPressed: i == options.length - 1 ? null : () => _move(i, 1),
                ),
                IconButton(
                  key: Key('journalOptionRemove_${options[i]}'),
                  tooltip: '「${options[i]}」を消す',
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: AppColors.error),
                  onPressed: () => _remove(options[i]),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('journalOptionInput'),
                controller: _ctrl,
                maxLength: AppSettings.maxJournalActivityLength,
                decoration: InputDecoration(
                  labelText: '新しい選択肢',
                  hintText: '例：読み聞かせ',
                  errorText: _error,
                  counterText: '',
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  key: const Key('journalOptionAdd'),
                  // テーマの最小サイズは横幅いっぱい（Size.fromHeight）なので、
                  // 入力欄の横に並べると幅が決まらず描かれない。最小を 48×48 にする
                  style:
                      ElevatedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('足す'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
