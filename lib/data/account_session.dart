import 'package:flutter/foundation.dart';

import '../models/staff.dart';
import '../services/staff_service.dart';

/// ログインしているアカウントの種類
enum AccountKind {
  /// 事業所の PC・タブレットで使う共用端末アカウント（メールアドレスとパスワード）。
  /// 誰が操作しているかは担当者の帯で選ぶ。
  shared,

  /// 職員個人の Google アカウント。担当者はログインした本人に固定。
  personal,
}

/// 「いまどの種類のアカウントで、誰としてログインしているか」。
///
/// memberships/{uid} の kind / staffId から決まる（DataSession が設定する）。
/// kind が無い所属は共用端末として扱う（ステップ1で作った所属）。
///
/// 管理者かどうかは「個人アカウントで、ひも付く職員が在籍中・ログイン許可・管理者」で
/// 判定する。共用端末アカウントは、担当者に管理者の名前を選んでいても管理者にならない
/// （名前を選ぶだけで管理者になれてしまうため）。ルール（firestore.rules）も同じ判定をする。
class AccountSession extends ChangeNotifier {
  AccountSession._() {
    StaffService.instance.addListener(notifyListeners);
  }
  static final AccountSession instance = AccountSession._();

  AccountKind _kind = AccountKind.shared;
  String? _staffId;

  AccountKind get kind => _kind;
  bool get isPersonal => _kind == AccountKind.personal;

  /// 個人アカウントにひも付く職員 ID（共用端末なら null）
  String? get staffId => _staffId;

  /// 個人アカウントにひも付く職員（共用端末・未登録なら null）
  Staff? get staff {
    final id = _staffId;
    if (!isPersonal || id == null) return null;
    return StaffService.instance.getById(id);
  }

  /// 管理者として操作できるか
  bool get isAdmin => staff?.isEffectiveAdmin ?? false;

  /// 管理者だけの項目を編集できない理由（編集できるなら null）
  String? get adminOnlyReason {
    if (isAdmin) return null;
    if (!isPersonal) {
      return '共用端末のアカウントでは変更できません。'
          '管理者が自分の Google アカウントでログインしたときに変更できます。';
    }
    return '管理者だけが変更できます。';
  }

  void setShared() {
    _kind = AccountKind.shared;
    _staffId = null;
    notifyListeners();
  }

  void setPersonal(String staffId) {
    _kind = AccountKind.personal;
    _staffId = staffId;
    notifyListeners();
  }

  /// ログアウト時
  void reset() => setShared();

  @visibleForTesting
  void debugSet({AccountKind kind = AccountKind.shared, String? staffId}) {
    _kind = kind;
    _staffId = staffId;
    notifyListeners();
  }
}
