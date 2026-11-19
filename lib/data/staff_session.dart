import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/staff.dart';
import '../services/staff_service.dart';
import 'audit.dart';

/// 担当者が選ばれていないため書き込みを中止したことを表す。
///
/// 画面側では「何もしない」で受け流してよい（選択画面は既に出ている）。
class StaffNotSelectedException implements Exception {
  const StaffNotSelectedException();
  @override
  String toString() => '担当者が選ばれていません';
}

/// 担当者を選ぶ画面を出して、選ばれた職員（キャンセルなら null）を返す関数
typedef StaffPrompter = Future<Staff?> Function();

/// 「いまの担当者」（端末ごと）
///
/// - ログインは事業所アカウントで共用。誰が操作しているかはここで選ぶ。
/// - 選んだ担当者は SharedPreferences に事業所ごとに保存する（他の端末には影響しない）。
/// - 選んだ職員が在籍終了になったら未選択に戻す。
/// - 日付が変わったら未選択に戻す（共用端末で前日の担当者のまま記録しないため）。
/// - ログアウトしたら端末の保存も消す（[clearSelection]。DataSession.logout から）。
/// - 他人の名前も選べるため厳密な本人確認ではない（現場の手軽さを優先）。
class StaffSession extends ChangeNotifier {
  StaffSession._();
  static final StaffSession instance = StaffSession._();

  static String prefsKey(String facilityId) => 'linkday.currentStaff.$facilityId';

  /// 担当者を選んだ日（"YYYY-MM-DD"）。今日と違えば未選択として扱う。
  static String prefsDateKey(String facilityId) =>
      'linkday.currentStaffDate.$facilityId';

  /// 現在時刻（テストで差し替える。担当者の帯の 0 時タイマーも使う）
  DateTime Function() clock = DateTime.now;

  String? _facilityId;
  String? _staffId;
  String? _selectedDay;

  String _today() {
    final n = clock();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// 画面側（main.dart）が登録する選択画面
  StaffPrompter? prompter;

  /// 暗証番号の確認（予約。このステップでは使わない）。
  /// 設定で有効にした場合に、担当者を切り替えるときだけ呼ぶ想定。
  Future<bool> Function(Staff staff)? pinVerifier;

  bool _listening = false;

  /// 現在の担当者。在籍終了・未登録の職員なら null。
  Staff? get current {
    final id = _staffId;
    if (id == null) return null;
    if (_selectedDay != _today()) {
      // 日付が変わった（タイマーより先に読まれた場合）: 未選択に戻す
      scheduleMicrotask(_onDayChanged);
      return null;
    }
    final s = StaffService.instance.getById(id);
    if (s == null || !s.isActive) return null;
    return s;
  }

  bool get hasStaff => current != null;

  /// 現在の担当者の記録用スタンプ（未選択なら null）
  AuditStamp? get stamp {
    final s = current;
    return s == null ? null : AuditStamp(staffId: s.id, staffName: s.name);
  }

  /// ログイン後に呼ぶ: この端末で前回選んだ担当者を読み出す
  Future<void> restore(String facilityId) async {
    _facilityId = facilityId;
    final prefs = await SharedPreferences.getInstance();
    _staffId = prefs.getString(prefsKey(facilityId));
    _selectedDay = prefs.getString(prefsDateKey(facilityId));
    if (_staffId != null && _selectedDay != _today()) {
      // 前日以前に選んだ担当者は引き継がない
      _staffId = null;
      _selectedDay = null;
      await prefs.remove(prefsKey(facilityId));
      await prefs.remove(prefsDateKey(facilityId));
    }
    if (!_listening) {
      StaffService.instance.addListener(_onStaffChanged);
      _listening = true;
    }
    notifyListeners();
  }

  /// ログアウト時: メモリ上の状態だけ消す（端末の保存は残す）
  void reset() {
    _facilityId = null;
    _staffId = null;
    _selectedDay = null;
    notifyListeners();
  }

  Future<void> select(Staff staff) async {
    final fid = _facilityId;
    if (staff.hasPin && pinVerifier != null) {
      final ok = await pinVerifier!(staff);
      if (!ok) return;
    }
    _staffId = staff.id;
    _selectedDay = _today();
    if (fid != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey(fid), staff.id);
      await prefs.setString(prefsDateKey(fid), _selectedDay!);
    }
    debugPrint('[StaffSession] selected ${staff.name}');
    notifyListeners();
  }

  Future<void> clearSelection() async {
    _staffId = null;
    _selectedDay = null;
    final fid = _facilityId;
    if (fid != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey(fid));
      await prefs.remove(prefsDateKey(fid));
    }
    notifyListeners();
  }

  /// 日付が変わっていれば未選択に戻す（画面を開いたまま 0 時をまたいだときに
  /// 担当者の帯から呼ぶ。記録の可否は [current] が日付で判定するので漏れない）
  void checkDay() => _onDayChanged();

  void _onDayChanged() {
    if (_staffId == null || _selectedDay == _today()) return;
    debugPrint('[StaffSession] 日付が変わったため担当者を未選択に戻します');
    unawaited(clearSelection());
  }

  /// 記録を変える操作の入口で呼ぶ。
  ///
  /// 担当者が選ばれていれば即座にスタンプを返す。未選択なら選択画面を出し、
  /// 選ばれなければ [StaffNotSelectedException] を投げて書き込みを中止させる。
  Future<AuditStamp> requireStamp() async {
    final s = stamp;
    if (s != null) return s;
    final p = prompter;
    if (p != null) {
      final chosen = await p();
      if (chosen != null) {
        await select(chosen);
        final after = stamp;
        if (after != null) return after;
      }
    }
    throw const StaffNotSelectedException();
  }

  void _onStaffChanged() {
    // 在籍終了などで current が null になった場合も画面の表示を更新する
    notifyListeners();
  }

  @visibleForTesting
  void debugSet({String? facilityId, String? staffId}) {
    _facilityId = facilityId;
    _staffId = staffId;
    _selectedDay = staffId == null ? null : _today();
    notifyListeners();
  }
}
