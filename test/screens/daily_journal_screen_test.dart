@Timeout(Duration(seconds: 120))
library;

// Flutter 3.50 で material.dart 全体が非推奨（既存テストと同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/audit.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/screens/daily_journal_screen.dart';
import 'package:linkday_app/services/attendance_service.dart';
import 'package:linkday_app/services/daily_journal_pdf_service.dart';
import 'package:linkday_app/services/daily_journal_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:linkday_app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階2: 業務日誌の画面
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DailyJournalService.instance.now = DateTime.now;
    DailyJournalService.instance.reset();
    StaffSession.instance.prompter = null;
    await FakeBackend.detach();
  });

  // 2026-11-25 は水曜日。職員 冬子は月水金、佐藤は火木、鈴木は勤務日なし
  const fuyuko = Staff(id: 's-a', name: '職員 冬子', workDays: [1, 3, 5]);
  const sato = Staff(id: 's-b', name: '佐藤', workDays: [2, 4]);
  const suzuki = Staff(id: 's-c', name: '鈴木');
  final today = DateTime(2026, 11, 25);
  DateTime at(int h, int m) => DateTime(2026, 11, 25, h, m);

  Future<T> io<T>(WidgetTester t, Future<T> Function() f) async =>
      (await t.runAsync(() async {
        final v = await f();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return v;
      })) as T;

  DocumentReference<Map<String, dynamic>> journalDoc(String id) {
    final b = FakeBackend.current;
    return b.db
        .collection(FsPaths.facilities)
        .doc(b.facilityId)
        .collection(FsPaths.dailyJournals)
        .doc(id);
  }

  Future<void> setUpData(WidgetTester t, {String? currentStaffId = 's-a'}) =>
      io(t, () async {
        await FakeBackend.attach(
            staff: const [fuyuko, sato, suzuki],
            currentStaffId: currentStaffId);
        DailyJournalService.instance.now = () => at(18, 0);
        await AttendanceService.instance.ensureDate(today);
        for (final r in [
          AttendanceRecord(
              customerId: 'c1',
              customerName: '架空 一郎',
              dateKey: '2026-11-25',
              status: AttendanceStatus.departed,
              checkInTime: at(14, 0),
              checkOutTime: at(17, 0)),
          AttendanceRecord(
              customerId: 'c2',
              customerName: '架空 花子',
              dateKey: '2026-11-25',
              status: AttendanceStatus.present,
              checkInTime: at(14, 30)),
          AttendanceRecord(
              customerId: 'c3',
              customerName: '架空 次郎',
              dateKey: '2026-11-25',
              status: AttendanceStatus.absent,
              absenceReason: '通院'),
        ]) {
          await AttendanceService.instance.upsertRecord(r,
              stamp: const AuditStamp(staffId: 's-a', staffName: '職員 冬子'));
        }
      });

  Future<void> open(WidgetTester t,
      {Size size = const Size(1280, 900),
      DateTime? date,
      Future<void> Function(JournalPrintData, DateTime)? printer}) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      home: DailyJournalScreen(initialDate: date ?? today, printer: printer),
    ));
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  bool selected(WidgetTester t, String key) =>
      t.widget<FilterChip>(find.byKey(Key(key))).selected;

  String text(WidgetTester t, String key) =>
      t.widget<Text>(find.byKey(Key(key))).data ?? '';

  Future<void> tapAndSettle(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await io(t, () async {});
    await t.pumpAndSettle();
  }

  testWidgets('今日の日誌: 勤務日が水曜の職員を最初から選び、入退室は出席の記録から出す', (t) async {
    await setUpData(t);
    await open(t);
    expect(text(t, 'journalDateLabel'), '2026年11月25日（水）　今日');
    expect(selected(t, 'journalStaff_s-a'), isTrue);
    expect(selected(t, 'journalStaff_s-b'), isFalse);
    expect(selected(t, 'journalStaff_s-c'), isFalse);
    expect(text(t, 'journalAttendanceText_c1'), '入室 14:00　退室 17:00');
    expect(text(t, 'journalAttendanceText_c2'), '入室 14:30　在室中');
    expect(text(t, 'journalAttendanceText_c3'), '欠席（通院）');
    // 未来の日へは進めない
    expect(
        t.widget<IconButton>(find.byKey(const Key('journalNextDay'))).onPressed,
        isNull);
    expect(find.text('準備中'), findsNothing);
  });

  testWidgets('文字を打たずに保存できる（職員と内容を押して選ぶだけ）。記録に担当者が残り、開き直しても同じ', (t) async {
    await setUpData(t);
    await open(t);
    await tapAndSettle(t, find.byKey(const Key('journalStaff_s-b')));
    await tapAndSettle(t, find.byKey(const Key('journalActivity_外遊び')));
    await tapAndSettle(t, find.byKey(const Key('journalActivity_おやつ')));
    expect(find.byKey(const Key('journalDirty')), findsOneWidget);
    await tapAndSettle(t, find.byKey(const Key('journalSave')));
    final d = (await io(t, () => journalDoc('2026-11-25').get())).data()!;
    expect(d['staff'], [
      {'staffId': 's-a', 'name': '職員 冬子'},
      {'staffId': 's-b', 'name': '佐藤'},
    ]);
    expect(d['activities'], ['外遊び', 'おやつ']);
    expect(d['note'], '');
    expect(d['updatedByStaffName'], '職員 冬子');
    expect(find.byKey(const Key('journalDirty')), findsNothing);

    // 開き直す（再読み込み・別の端末で開くのに相当）
    await t.pumpWidget(const SizedBox.shrink());
    await open(t);
    expect(selected(t, 'journalStaff_s-a'), isTrue);
    expect(selected(t, 'journalStaff_s-b'), isTrue);
    expect(selected(t, 'journalActivity_外遊び'), isTrue);
    expect(selected(t, 'journalActivity_おやつ'), isTrue);
    expect(selected(t, 'journalActivity_工作'), isFalse);
    expect(text(t, 'journalWriter'), startsWith('記入者：職員 冬子'));
  });

  testWidgets('担当者が未選択なら保存されず、選ぶと保存されて記録にその担当者が残る', (t) async {
    await setUpData(t, currentStaffId: null);
    var chosen = false;
    StaffSession.instance.prompter = () async {
      if (!chosen) return null; // 1 回目は選ぶ画面を閉じる
      return sato;
    };
    await open(t);
    await tapAndSettle(t, find.byKey(const Key('journalSave')));
    expect(find.text('担当者を選ぶと保存できます'), findsOneWidget);
    expect((await io(t, () => journalDoc('2026-11-25').get())).exists, isFalse);
    chosen = true;
    await t.pumpAndSettle(const Duration(seconds: 5));
    await tapAndSettle(t, find.byKey(const Key('journalSave')));
    final d = (await io(t, () => journalDoc('2026-11-25').get())).data()!;
    expect(d['updatedByStaffId'], 's-b');
    expect(d['updatedByStaffName'], '佐藤');
  });

  testWidgets('出席管理で時刻を直すと、日誌の表示が開き直さずに変わる', (t) async {
    await setUpData(t);
    await open(t);
    expect(text(t, 'journalAttendanceText_c1'), '入室 14:00　退室 17:00');
    await io(
        t,
        () => AttendanceService.instance.updateCheckInTime(
            customerId: 'c1', date: today, newTime: at(14, 15)));
    await t.pumpAndSettle();
    expect(text(t, 'journalAttendanceText_c1'), '入室 14:15　退室 17:00');
  });

  testWidgets('前の日へ移る。保存していない変更があれば確かめ、やめれば残る', (t) async {
    await setUpData(t);
    await open(t);
    await tapAndSettle(t, find.byKey(const Key('journalActivity_工作')));
    await tapAndSettle(t, find.byKey(const Key('journalPrevDay')));
    expect(find.text('保存していない変更があります'), findsWidgets);
    await tapAndSettle(t, find.byKey(const Key('journalDiscardCancel')));
    expect(text(t, 'journalDateLabel'), '2026年11月25日（水）　今日');
    expect(selected(t, 'journalActivity_工作'), isTrue);
    await tapAndSettle(t, find.byKey(const Key('journalPrevDay')));
    await tapAndSettle(t, find.byKey(const Key('journalDiscardOk')));
    expect(text(t, 'journalDateLabel'), '2026年11月24日（火）');
    // 火曜日: 佐藤が最初から選ばれる
    expect(selected(t, 'journalStaff_s-b'), isTrue);
    expect(selected(t, 'journalStaff_s-a'), isFalse);
    expect(
        t.widget<IconButton>(find.byKey(const Key('journalNextDay'))).onPressed,
        isNotNull);
  });

  testWidgets('保存していない変更があるまま画面を離れようとしたら確かめる', (t) async {
    await setUpData(t);
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
                c,
                MaterialPageRoute(
                    builder: (_) => DailyJournalScreen(initialDate: today))),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await tapAndSettle(t, find.text('開く'));
    await tapAndSettle(t, find.byKey(const Key('journalActivity_工作')));
    await t.binding.handlePopRoute();
    await io(t, () async {});
    await t.pumpAndSettle();
    expect(find.byType(DailyJournalScreen), findsOneWidget);
    expect(find.text('保存していない変更があります'), findsWidgets);
    await tapAndSettle(t, find.byKey(const Key('journalDiscardOk')));
    expect(find.byType(DailyJournalScreen), findsNothing);
  });

  testWidgets('他の端末で保存されたとき: 入力中なら消さずに知らせ、入力が無ければそのまま表示を変える', (t) async {
    await setUpData(t);
    await open(t);
    // 入力が無い（保存していない変更なし）とき
    await tapAndSettle(t, find.byKey(const Key('journalSave')));
    await io(
        t,
        () => journalDoc('2026-11-25').set({
              'activities': ['散歩'],
              'updatedByStaffName': '佐藤'
            }, SetOptions(merge: true)));
    await t.pumpAndSettle();
    expect(selected(t, 'journalActivity_散歩'), isTrue);
    expect(find.byKey(const Key('journalRemoteBanner')), findsNothing);

    // 入力中のとき
    await tapAndSettle(t, find.byKey(const Key('journalActivity_工作')));
    await io(
        t,
        () => journalDoc('2026-11-25').set({
              'activities': ['運動'],
              'updatedByStaffName': '佐藤'
            }, SetOptions(merge: true)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('journalRemoteBanner')), findsOneWidget);
    expect(selected(t, 'journalActivity_工作'), isTrue); // 入力は消えない
    expect(selected(t, 'journalActivity_散歩'), isTrue);
    await tapAndSettle(t, find.byKey(const Key('journalShowLatest')));
    expect(selected(t, 'journalActivity_運動'), isTrue);
    expect(selected(t, 'journalActivity_工作'), isFalse);
    expect(find.byKey(const Key('journalRemoteBanner')), findsNothing);
  });

  testWidgets('設定から消した選択肢も、過去の日誌にはそのとき選んだ名前で残る', (t) async {
    await setUpData(t);
    await io(t, () async {
      await journalDoc('2026-11-20').set({
        'date': '2026-11-20',
        'staff': [
          {'staffId': 'gone', 'name': '退職した職員'}
        ],
        'activities': ['調理'],
        'note': '架空の備考',
        'updatedByStaffName': '職員 冬子',
      });
      await SettingsService.instance
          .updateJournalActivityOptions(['外遊び', 'おやつ']); // 「調理」を消した
    });
    await open(t, date: DateTime(2026, 11, 20));
    expect(selected(t, 'journalActivity_調理'), isTrue);
    expect(find.byKey(const Key('journalActivity_工作')), findsNothing);
    expect(find.text('退職した職員（在籍終了）'), findsOneWidget);
    expect(find.text('架空の備考'), findsOneWidget);
  });

  testWidgets('印刷: 保存してから、保存した内容と出席の記録で印刷の中身を作る', (t) async {
    await setUpData(t);
    JournalPrintData? printed;
    await open(t, printer: (d, _) async => printed = d);
    await tapAndSettle(t, find.byKey(const Key('journalActivity_外遊び')));
    await tapAndSettle(t, find.byKey(const Key('journalPrint')));
    expect(find.text('保存してから印刷します'), findsOneWidget);
    await tapAndSettle(t, find.byKey(const Key('journalSaveAndPrint')));
    expect(printed, isNotNull);
    expect(printed!.staffNames, ['職員 冬子']);
    expect(printed!.activities, ['外遊び']);
    expect(printed!.attendanceRows.first, ['架空 一郎', '14:00', '17:00', '退室済み']);
    expect(printed!.writer, startsWith('職員 冬子'));
    expect((await io(t, () => journalDoc('2026-11-25').get())).exists, isTrue);
  });

  testWidgets('利用者が多くても、保存のボタンはスクロールせずに押せる。広い幅では内容の選択肢も最初から見える', (t) async {
    await setUpData(t);
    await io(t, () async {
      for (var i = 0; i < 25; i++) {
        await AttendanceService.instance.upsertRecord(
            AttendanceRecord(
                customerId: 'm$i',
                customerName: '架空 多人数$i',
                dateKey: '2026-11-25',
                status: AttendanceStatus.departed,
                checkInTime: at(14, i),
                checkOutTime: at(17, i)),
            stamp: const AuditStamp(staffId: 's-a', staffName: '職員 冬子'));
      }
    });
    for (final size in const [Size(1280, 900), Size(530, 900)]) {
      await t.pumpWidget(const SizedBox.shrink());
      await open(t, size: size);
      final save = t.getRect(find.byKey(const Key('journalSave')));
      expect(save.bottom, lessThanOrEqualTo(size.height),
          reason: '幅 ${size.width}');
      await t.tap(find.byKey(const Key('journalSave')));
      await io(t, () async {});
      await t.pumpAndSettle();
      expect(
          (await io(t, () => journalDoc('2026-11-25').get())).exists, isTrue);
    }
    // 幅 1280: 2 列（入退室は右）なので、内容の選択肢がスクロールせずに見える
    await t.pumpWidget(const SizedBox.shrink());
    await open(t, size: const Size(1280, 900));
    expect(t.getRect(find.byKey(const Key('journalActivity_外遊び'))).bottom,
        lessThan(900));
  });

  for (final size in const [Size(1280, 900), Size(820, 1180), Size(530, 900)]) {
    testWidgets('幅 ${size.width.toInt()} で崩れない。押す場所は高さ 48 以上', (t) async {
      await setUpData(t);
      await open(t, size: size);
      expect(t.takeException(), isNull);
      for (final k in [
        'journalStaff_s-a',
        'journalActivity_外遊び',
        'journalSave',
        'journalPrevDay',
        'journalPickDate',
      ]) {
        final f = find.byKey(Key(k));
        await t.ensureVisible(f);
        await t.pumpAndSettle();
        expect(t.getSize(f).height, greaterThanOrEqualTo(48), reason: k);
      }
      final right = t.getTopRight(find.byKey(const Key('journalSave'))).dx;
      expect(right, lessThanOrEqualTo(size.width));
    });
  }
}
