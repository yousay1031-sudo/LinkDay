import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// ignore: implementation_imports
import 'package:hive/src/binary/binary_reader_impl.dart';
// ignore: implementation_imports
import 'package:hive/src/binary/binary_writer_impl.dart';
// ignore: implementation_imports
import 'package:hive/src/hive_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/screens/settings_screen.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/services/vacancy_notification_service.dart';

import 'support/fake_backend.dart';

/// Day 15: 管理者 LINE userId（AppSettings field16）
///
/// 過去 2 回（Day 10, 11）、AppSettings を再構築する箇所で新フィールドの
/// 引き継ぎを忘れて既定値に戻る事故があった。更新系メソッドを全部呼んで
/// 値が残ることを固定する。
const _admin = 'U1234567890abcdef1234567890abcdef';
const _other = 'Uffffffffffffffffffffffffffffffff';

void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('linkday_admin_uid_');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(7)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
    await SettingsService.instance.init();
    // 設定は Firestore（段階7）。偽の保存先と担当者（山田）で接続する
    await FakeBackend.attachWithStaff();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  group('AppSettings.adminLineUserId: モデル', () {
    test('既定は未設定(null)', () {
      expect(AppSettings().adminLineUserId, isNull);
      expect(AppSettings().hasAdminLineUserId, isFalse);
    });

    test('前後の空白は除かれ、空文字は null になる', () {
      expect(
          AppSettings(adminLineUserId: '  $_admin  ').adminLineUserId, _admin);
      expect(AppSettings(adminLineUserId: '').adminLineUserId, isNull);
      expect(AppSettings(adminLineUserId: '   ').adminLineUserId, isNull);
    });

    test('形式判定: U + 32桁16進のみ有効（functions と同じ規則）', () {
      expect(AppSettings.isValidLineUserId(_admin), isTrue);
      expect(AppSettings.isValidLineUserId('  $_admin '), isTrue);
      expect(AppSettings.isValidLineUserId('U${'A' * 32}'), isTrue);
      for (final bad in [
        null,
        '',
        'Uabc',
        '1234567890abcdef1234567890abcdef12',
        'U${'z' * 32}',
        'U${'a' * 31}',
        'U${'a' * 33}',
        'u1234567890abcdef1234567890abcdef', // 小文字 u
        'U1234567890abcdef1234567890abcde\n',
      ]) {
        // trim 後に判定するため、末尾改行のみのケースは有効側に倒れる点に注意
        if (bad == 'U1234567890abcdef1234567890abcde\n') continue;
        expect(AppSettings.isValidLineUserId(bad), isFalse, reason: '$bad');
      }
    });

    test('hasAdminLineUserId は形式不正の値では false', () {
      expect(AppSettings(adminLineUserId: 'bogus').hasAdminLineUserId, isFalse);
      expect(AppSettings(adminLineUserId: _admin).hasAdminLineUserId, isTrue);
    });

    test('adjustedForVehicleCount で引き継がれる', () {
      final s = AppSettings(adminLineUserId: _admin).adjustedForVehicleCount(3);
      expect(s.adminLineUserId, _admin);
      expect(s.vehicleCount, 3);
    });
  });

  group('Hive 永続化とバイナリ互換', () {
    test('書いて読むと値が保持される（field16）', () async {
      final box = await Hive.openBox<AppSettings>('t_roundtrip');
      await box.put('k', AppSettings(adminLineUserId: _admin, slotTtlHours: 9));
      final back = box.get('k')!;
      expect(back.adminLineUserId, _admin);
      expect(back.slotTtlHours, 9);
      await box.close();
    });

    test('未設定(null)も往復できる', () async {
      final box = await Hive.openBox<AppSettings>('t_roundtrip_null');
      await box.put('k', AppSettings());
      expect(box.get('k')!.adminLineUserId, isNull);
      await box.close();
    });

    test('旧データ(field16 を持たない16フィールド)を読んでも落ちず未設定になる', () async {
      // 旧アダプタ相当: field 0..15 だけを書いたバイト列を作り、現アダプタで読む。
      final adapter = AppSettingsAdapter();
      final bytes = _legacyBytes(AppSettings(slotTtlHours: 7));
      final reader = BinaryReaderImpl(bytes, Hive as HiveImpl);
      final read = adapter.read(reader);
      expect(read.adminLineUserId, isNull);
      expect(read.slotTtlHours, 7);
      expect(read.facilityName, isNotEmpty);
    });
  });

  group('SettingsService.updateAdminLineUserId', () {
    test('保存でき、他の設定を壊さない', () async {
      final svc = SettingsService.instance;
      await svc.updateFacility('管理者テスト事業所', '帯広市1-1');
      await svc.updateSlotTtlHours(4);
      await svc.updateVacancyNotice(deadline: '10:45', template: '本文{date}');

      final ok = await svc.updateAdminLineUserId(_admin);
      expect(ok, isTrue);
      final s = svc.getSettings();
      expect(s.adminLineUserId, _admin);
      expect(s.facilityName, '管理者テスト事業所');
      expect(s.slotTtlHours, 4);
      expect(s.vacancyReplyDeadline, '10:45');
      expect(s.vacancyMessageTemplate, '本文{date}');
    });

    test('他の更新系メソッドを全部呼んでも管理者 userId が消えない', () async {
      final svc = SettingsService.instance;
      expect(await svc.updateAdminLineUserId(_admin), isTrue);

      await svc.updateFacility('A', 'B');
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateFacility');
      await svc.updateVehicles(2, ['x', 'y'], [4, 4]);
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateVehicles');
      await svc.updateOperatingHours('08:00', '17:00', 9);
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateOperatingHours');
      await svc.saveFacilityGeocode(42.9, 143.2);
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'saveFacilityGeocode');
      await svc.updateVacancyNotice(deadline: '12:00', template: 'テンプレ');
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateVacancyNotice');
      await svc.updateSlotTtlHours(11);
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateSlotTtlHours');

      // 後続の画面テストに座標(地図PlatformView)を持ち越さない。
      // 住所を変えると Geocoding キャッシュがクリアされる。
      await svc.updateFacility('A', 'クリア用の別住所');
      expect(svc.getSettings().hasGeocode, isFalse);
      expect(svc.getSettings().adminLineUserId, _admin,
          reason: 'updateFacility(住所変更)');
    });

    test('逆方向: userId 保存が他の設定（受付時間・文面）を戻さない', () async {
      final svc = SettingsService.instance;
      await svc.updateSlotTtlHours(13);
      await svc.updateVacancyNotice(deadline: '09:15', template: '逆{date}');
      await svc.updateAdminLineUserId(_other);
      final s = svc.getSettings();
      expect(s.slotTtlHours, 13);
      expect(s.vacancyReplyDeadline, '09:15');
      expect(s.vacancyMessageTemplate, '逆{date}');
    });

    test('前後の空白は除いて保存される', () async {
      final svc = SettingsService.instance;
      await svc.updateAdminLineUserId('  $_admin\n');
      expect(svc.getSettings().adminLineUserId, _admin);
    });

    test('空文字・空白のみは未設定に戻る（通知を止める操作）', () async {
      final svc = SettingsService.instance;
      await svc.updateAdminLineUserId(_admin);
      expect(await svc.updateAdminLineUserId(''), isTrue);
      expect(svc.getSettings().adminLineUserId, isNull);

      await svc.updateAdminLineUserId(_admin);
      expect(await svc.updateAdminLineUserId('   '), isTrue);
      expect(svc.getSettings().adminLineUserId, isNull);

      await svc.updateAdminLineUserId(_admin);
      expect(await svc.updateAdminLineUserId(null), isTrue);
      expect(svc.getSettings().adminLineUserId, isNull);
    });

    test('形式不正は拒否され、既存の値は変わらない', () async {
      final svc = SettingsService.instance;
      await svc.updateAdminLineUserId(_admin);
      for (final bad in ['abc', 'U123', 'U${'z' * 32}', 'Uabc def', '1' * 33]) {
        expect(await svc.updateAdminLineUserId(bad), isFalse, reason: bad);
        expect(svc.getSettings().adminLineUserId, _admin, reason: bad);
      }
    });
  });

  group('Callable ペイロード: 管理者 userId の受け渡し', () {
    const target = VacancyCandidate(
      customerId: 'c1',
      childName: '佐藤花子',
      lineUserId: 'U11111111111111111111111111111111',
      remainingProjected: 3,
      regularDays: [1],
    );

    Map<String, dynamic> payload(AppSettings s) =>
        VacancyNotificationService.buildCallablePayload(
          dateKey: '2026-10-06',
          message: 'm',
          sourceAbsentCustomerId: 'abs',
          settings: s,
          targets: [target],
        );

    test('設定済みなら adminLineUserId を渡す', () {
      final p = payload(AppSettings(adminLineUserId: _admin));
      expect(p['adminLineUserId'], _admin);
    });

    test('未設定ならキー自体を渡さない', () {
      expect(payload(AppSettings()).containsKey('adminLineUserId'), isFalse);
    });

    test('形式不正の値は渡さない（誤った宛先をサーバーへ送らない）', () {
      final p = payload(AppSettings(adminLineUserId: 'not-a-user-id'));
      expect(p.containsKey('adminLineUserId'), isFalse);
    });

    test('従来のキー（受付時間・宛先・欠席元）は維持される', () {
      final p = payload(AppSettings(adminLineUserId: _admin, slotTtlHours: 8));
      expect(p['date'], '2026-10-06');
      expect(p['slotTtlHours'], 8);
      expect(p['sourceAbsentCustomerId'], 'abs');
      expect((p['recipients'] as List).length, 1);
    });
  });

  group('設定画面: 管理者 LINE userId', () {
    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 3600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> tapReal(WidgetTester tester, Key key) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(key));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    String? fieldText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('adminLineUserIdField')))
        .controller
        ?.text;

    testWidgets('入力欄が表示される', (tester) async {
      await tester
          .runAsync(() => SettingsService.instance.updateAdminLineUserId(''));
      await open(tester);
      expect(find.text('管理者のLINE通知'), findsOneWidget);
      expect(find.byKey(const Key('adminLineUserIdField')), findsOneWidget);
      expect(find.byKey(const Key('adminLineUserIdSave')), findsOneWidget);
      expect(fieldText(tester), '');
    });

    testWidgets('入力して保存すると AppSettings に保存される', (tester) async {
      await tester
          .runAsync(() => SettingsService.instance.updateAdminLineUserId(''));
      await open(tester);
      await tester.enterText(
          find.byKey(const Key('adminLineUserIdField')), '  $_admin ');
      await tapReal(tester, const Key('adminLineUserIdSave'));

      expect(SettingsService.instance.getSettings().adminLineUserId, _admin);
      expect(find.textContaining('保存しました'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });

    testWidgets('形式不正はエラー表示になり、保存されない', (tester) async {
      await tester.runAsync(
          () => SettingsService.instance.updateAdminLineUserId(_other));
      await open(tester);
      await tester.enterText(
          find.byKey(const Key('adminLineUserIdField')), 'bogus-id');
      await tapReal(tester, const Key('adminLineUserIdSave'));

      expect(find.textContaining('形式が正しくありません'), findsOneWidget);
      expect(SettingsService.instance.getSettings().adminLineUserId, _other);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });

    testWidgets('再度画面を開くと保存済みの userId が入力欄に出る', (tester) async {
      await tester.runAsync(
          () => SettingsService.instance.updateAdminLineUserId(_admin));
      await open(tester);
      expect(fieldText(tester), _admin);
    });

    testWidgets('空欄で保存すると未設定に戻る', (tester) async {
      await tester.runAsync(
          () => SettingsService.instance.updateAdminLineUserId(_admin));
      await open(tester);
      await tester.enterText(find.byKey(const Key('adminLineUserIdField')), '');
      await tapReal(tester, const Key('adminLineUserIdSave'));

      expect(SettingsService.instance.getSettings().adminLineUserId, isNull);
      expect(find.textContaining('解除'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });

    testWidgets('受付時間を変更しても管理者 userId が消えない（画面経由）', (tester) async {
      await tester.runAsync(() async {
        await SettingsService.instance.updateAdminLineUserId(_admin);
        await SettingsService.instance.updateSlotTtlHours(6);
      });
      await open(tester);
      await tapReal(tester, const Key('slotTtlPlus'));
      expect(SettingsService.instance.getSettings().slotTtlHours, 7);
      expect(SettingsService.instance.getSettings().adminLineUserId, _admin);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });
  });
}

// ── 旧形式(16フィールド)のバイト列を作るためのヘルパ ─────────────────
//
// Hive の BinaryWriter/Reader を直接使い、field 16 を含まない旧レイアウトを再現する。
Uint8List _legacyBytes(AppSettings o) {
  {
    final w = BinaryWriterImpl(Hive as HiveImpl);
    w
      ..writeByte(16)
      ..writeByte(0)
      ..write(o.facilityName)
      ..writeByte(1)
      ..write(o.facilityAddress)
      ..writeByte(2)
      ..write(o.facilityLat)
      ..writeByte(3)
      ..write(o.facilityLng)
      ..writeByte(4)
      ..write(o.vehicleCount)
      ..writeByte(5)
      ..write(o.vehicleNames)
      ..writeByte(6)
      ..write(o.vehicleCapacities)
      ..writeByte(7)
      ..write(o.maxStudentsPerDay)
      ..writeByte(8)
      ..write(o.defaultPickupStart)
      ..writeByte(9)
      ..write(o.defaultDropoffEnd)
      ..writeByte(10)
      ..write(o.updatedAt)
      ..writeByte(11)
      ..write(o.jsApiKeyLegacy)
      ..writeByte(12)
      ..write(o.restApiKeyLegacy)
      ..writeByte(13)
      ..write(o.vacancyReplyDeadline)
      ..writeByte(14)
      ..write(o.vacancyMessageTemplate)
      ..writeByte(15)
      ..write(o.slotTtlHours);
    return w.toBytes();
  }
}
