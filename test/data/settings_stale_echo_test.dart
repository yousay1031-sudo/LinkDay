import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/pending_echoes.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// 続けて保存したとき、前の保存の折り返しが後から届いても、設定が古い内容に戻らないこと。
///
/// 以前は admin_line_user_id_test の「保存でき、他の設定を壊さない」が、テストの順序に
/// よって（前のテストの書き込みの折り返しが後から届いて）受付時間 4 → 11 に戻り失敗していた。
SettingsService get _svc => SettingsService.instance;

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FakeBackend.attachWithStaff();
  });
  tearDown(FakeBackend.detach);

  test('続けて保存: 後の保存の後に、前の保存の内容に戻らない', () async {
    await _svc.updateSlotTtlHours(8); // 保存先の文書を作る
    await _drain();

    await _svc.updateSlotTtlHours(11);
    await _svc.updateSlotTtlHours(4);
    final seen = <int>[];
    void onChange() => seen.add(_svc.getSettings().slotTtlHours);
    _svc.addListener(onChange);
    addTearDown(() => _svc.removeListener(onChange));

    expect(_svc.getSettings().slotTtlHours, 4);
    await _drain();
    expect(seen.where((v) => v != 4), isEmpty,
        reason: '保存した後に古い内容（11 など）が見えてはいけない: $seen');
    expect(_svc.getSettings().slotTtlHours, 4);
  });

  test('別々の項目を続けて保存しても、前の保存の項目が古い値に戻らない', () async {
    await _svc.updateSlotTtlHours(8);
    await _drain();
    await _svc.updateFacility('前の事業所', '前の住所');
    await _svc.updateSlotTtlHours(11);
    await _svc.updateFacility('管理者テスト事業所', '帯広市1-1');
    await _svc.updateSlotTtlHours(4);
    await _svc.updateVacancyNotice(deadline: '10:45', template: '本文{date}');
    await _drain();
    final s = _svc.getSettings();
    expect(s.slotTtlHours, 4);
    expect(s.facilityName, '管理者テスト事業所');
    expect(s.vacancyReplyDeadline, '10:45');
  });

  test('他の端末の変更（自分が送っていない内容）は反映される', () async {
    await _svc.updateSlotTtlHours(8);
    await _drain();
    await FacilityContext.instance
        .col(FsPaths.settings)
        .doc(FsPaths.settingsDocId)
        .update({'slotTtlHours': 20});
    await _drain();
    expect(_svc.getSettings().slotTtlHours, 20);
  });

  group('PendingEchoes', () {
    Map<String, dynamic> st(int v) => {'v': v};

    test('最後に送った内容の折り返しは反映、それより前の折り返しは無視', () {
      final e = PendingEchoes()
        ..add(st(11))
        ..add(st(4));
      expect(e.isStaleEcho(st(11)), isTrue);
      expect(e.isStaleEcho(st(4)), isFalse);
      expect(e.isEmpty, isTrue);
    });

    test('送っていない内容は他の端末の変更として扱う', () {
      final e = PendingEchoes()..add(st(4));
      expect(e.isStaleEcho(st(99)), isFalse);
    });

    test('同じ内容を 2 回送った（11 → 4 → 11）: 最後の 11 は反映', () {
      final e = PendingEchoes()
        ..add(st(11))
        ..add(st(4))
        ..add(st(11));
      expect(e.isStaleEcho(st(11)), isTrue);
      expect(e.isStaleEcho(st(4)), isTrue);
      expect(e.isStaleEcho(st(11)), isFalse);
    });
  });
}
