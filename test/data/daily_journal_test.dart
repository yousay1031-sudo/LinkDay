import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/data/facility_context.dart';
import 'package:linkday_app/data/staff_session.dart';
import 'package:linkday_app/models/app_settings.dart';
import 'package:linkday_app/models/attendance_record.dart';
import 'package:linkday_app/models/daily_journal.dart';
import 'package:linkday_app/models/staff.dart';
import 'package:linkday_app/services/daily_journal_pdf_service.dart';
import 'package:linkday_app/services/daily_journal_service.dart';
import 'package:linkday_app/services/settings_service.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_backend.dart';

/// ステップ3 段階2: 業務日誌（保存・入退室の行・選択肢の設定・印刷の中身）
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    DailyJournalService.instance.now = DateTime.now;
    DailyJournalService.instance.reset();
    await FakeBackend.detach();
  });

  // 2026-11-25 は水曜日
  final wed = DateTime(2026, 11, 25);
  DateTime at(int h, int m) => DateTime(2026, 11, 25, h, m);

  CollectionReference<Map<String, dynamic>> col(FakeBackend b) => b.db
      .collection(FsPaths.facilities)
      .doc(b.facilityId)
      .collection(FsPaths.dailyJournals);

  group('利用者の入退室時間（出席の記録から作る。保存しない）', () {
    final records = [
      AttendanceRecord(
          customerId: 'c-absent',
          customerName: 'あ 欠席',
          dateKey: '2026-11-25',
          status: AttendanceStatus.absent,
          absenceReason: '体調不良'),
      AttendanceRecord(
          customerId: 'c-absent2',
          customerName: 'い 欠席',
          dateKey: '2026-11-25',
          status: AttendanceStatus.absent),
      AttendanceRecord(
          customerId: 'c-late',
          customerName: 'う 遅く入室',
          dateKey: '2026-11-25',
          status: AttendanceStatus.departed,
          checkInTime: at(15, 0),
          checkOutTime: at(17, 30)),
      AttendanceRecord(
          customerId: 'c-in',
          customerName: 'え 在室',
          dateKey: '2026-11-25',
          status: AttendanceStatus.present,
          checkInTime: at(14, 5)),
      AttendanceRecord(
          customerId: 'c-plan',
          customerName: 'お 予定',
          dateKey: '2026-11-25',
          status: AttendanceStatus.scheduled),
    ];

    test('並びは 入室した人（入室の早い順）→ 未入室 → 欠席。欠席は理由つき、在室中は「在室中」', () {
      final rows = JournalAttendanceRow.fromRecords(records);
      expect(rows.map((r) => r.customerId),
          ['c-in', 'c-late', 'c-plan', 'c-absent', 'c-absent2']);
      expect([rows[0].inText, rows[0].outText, rows[0].statusText],
          ['14:05', '在室中', '在室中']);
      expect([rows[1].inText, rows[1].outText, rows[1].statusText],
          ['15:00', '17:30', '退室済み']);
      expect([rows[2].inText, rows[2].outText, rows[2].statusText],
          ['', '', '未入室']);
      expect(rows[3].statusText, '欠席（体調不良）');
      expect(rows[4].statusText, '欠席');
    });
  });

  group('今日いた職員の初期値', () {
    test('在籍中で、勤務日がその曜日に当たる職員だけを選ぶ', () {
      const staff = [
        Staff(id: 'mon-wed', name: '月水', workDays: [1, 3]),
        Staff(id: 'thu', name: '木', workDays: [4]),
        Staff(id: 'none', name: '未設定'),
        Staff(id: 'gone', name: '退職', workDays: [3], isActive: false),
      ];
      expect(
          DailyJournalService.defaultStaffFor(wed, staff).map((s) => s.staffId),
          ['mon-wed']);
      expect(
          DailyJournalService.defaultStaffFor(
                  DateTime(2026, 11, 26), staff) // 木曜日
              .map((s) => s.staffId),
          ['thu']);
    });
  });

  group('保存', () {
    test('担当者の記録と作成日時つきで 1 日 1 文書（文書 ID は日付）。直すと同じ文書が変わる', () async {
      final b = await FakeBackend.attachWithStaff();
      DailyJournalService.instance.now = () => at(18, 0);
      const j = DailyJournal(
        dateKey: '2026-11-25',
        staff: [JournalStaff(staffId: 's-a', name: '職員 冬子')],
        activities: ['外遊び', 'おやつ'],
      );
      await DailyJournalService.instance.save(j, exists: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var docs = (await col(b).get()).docs;
      expect(docs.map((d) => d.id), ['2026-11-25']);
      final d = docs.single.data();
      expect(d['date'], '2026-11-25');
      expect(d['staff'], [
        {'staffId': 's-a', 'name': '職員 冬子'}
      ]);
      expect(d['activities'], ['外遊び', 'おやつ']);
      expect(d['note'], ''); // 備考は空でも保存できる
      expect(d['updatedByStaffId'], 's-a');
      expect(d['updatedByStaffName'], '職員 冬子');
      expect(d.containsKey('createdAt'), isTrue);

      await DailyJournalService.instance
          .save(j.copyWith(note: '雨のため室内'), exists: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      docs = (await col(b).get()).docs;
      expect(docs.length, 1);
      expect(docs.single.data()['note'], '雨のため室内');
    });

    test('未来の日は保存できない（今日は保存できる）', () async {
      final b = await FakeBackend.attachWithStaff();
      DailyJournalService.instance.now = () => at(9, 0);
      await expectLater(
          DailyJournalService.instance
              .save(const DailyJournal(dateKey: '2026-11-26'), exists: false),
          throwsA(isA<JournalFutureDateException>()));
      await DailyJournalService.instance
          .save(const DailyJournal(dateKey: '2026-11-25'), exists: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await col(b).get()).docs.map((d) => d.id), ['2026-11-25']);
    });

    test('担当者が未選択なら保存しない（選ぶ画面を閉じたら書き込まない）', () async {
      final b = await FakeBackend.attach(staff: const [FakeBackend.staffA]);
      DailyJournalService.instance.now = () => at(9, 0);
      StaffSession.instance.prompter = () async => null;
      addTearDown(() => StaffSession.instance.prompter = null);
      await expectLater(
          DailyJournalService.instance
              .save(const DailyJournal(dateKey: '2026-11-25'), exists: false),
          throwsA(isA<StaffNotSelectedException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await col(b).get()).docs, isEmpty);
    });

    test('読み書きの往復: 保存した内容が同じ形で読める（在籍終了の職員の名前も残る）', () {
      const j = DailyJournal(
        dateKey: '2026-11-25',
        staff: [
          JournalStaff(staffId: 's-a', name: '職員 冬子'),
          JournalStaff(staffId: null, name: '外部の応援'),
        ],
        activities: ['消した選択肢'],
        note: 'メモ',
      );
      final back =
          DailyJournal.fromFirestore('2026-11-25', j.toFirestoreData());
      expect(back.sameContent(j), isTrue);
      expect(back.staff[1].name, '外部の応援');
    });
  });

  group('「その日の内容」の選択肢（設定の文書に持つ）', () {
    test('未保存なら初期値の 11 個。空のリストは「すべて消した」として空のまま', () {
      expect(AppSettings.fromFirestore(const {}).journalActivityOptions,
          AppSettings.defaultJournalActivityOptions);
      expect(AppSettings.defaultJournalActivityOptions.length, 11);
      expect(
          AppSettings.fromFirestore(const {'journalActivityOptions': []})
              .journalActivityOptions,
          isEmpty);
    });

    test('空白・空・重複・長すぎるものは除く', () {
      expect(
          AppSettings.normalizeJournalActivityOptions(
              [' 外遊び ', '', '外遊び', 'x' * 31, '読み聞かせ']),
          ['外遊び', '読み聞かせ']);
    });

    test('選択肢を保存した後、他の設定を保存しても選択肢は初期値に戻らない', () async {
      final b = await FakeBackend.attachWithStaff();
      final s = SettingsService.instance;
      await s.updateJournalActivityOptions(['読み聞かせ', '外遊び']);
      await s.updateFacility('架空の事業所', '架空の住所');
      await s.updateSlotTtlHours(5);
      await s.updateVacancyNotice(deadline: '12:00', template: '本文');
      await s.updateAdminLineUserId(null);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(s.getSettings().journalActivityOptions, ['読み聞かせ', '外遊び']);
      final stored = (await b.db
              .collection(FsPaths.facilities)
              .doc(b.facilityId)
              .collection(FsPaths.settings)
              .doc(FsPaths.settingsDocId)
              .get())
          .data()!;
      expect(stored['journalActivityOptions'], ['読み聞かせ', '外遊び']);
      expect(stored['updatedByStaffName'], '職員 冬子');
    });
  });

  group('印刷の中身', () {
    final journal = DailyJournal(
      dateKey: '2026-11-25',
      staff: const [
        JournalStaff(staffId: 's-a', name: '職員 冬子'),
        JournalStaff(staffId: 's-b', name: '佐藤'),
      ],
      activities: const ['外遊び', '設定から消した選択肢'],
      note: '架空の備考',
      updatedAt: at(18, 5),
      updatedByStaffName: '職員 冬子',
    );
    final rows = [
      JournalAttendanceRow(
          customerId: 'c1',
          name: '架空 一郎',
          status: AttendanceStatus.departed,
          checkIn: at(14, 0),
          checkOut: at(17, 0)),
      const JournalAttendanceRow(
          customerId: 'c2',
          name: '架空 花子',
          status: AttendanceStatus.absent,
          absenceReason: '通院'),
    ];

    test('日付・事業所名・職員・利用者と入退室時間・内容・備考・記入者を、この順に出す', () {
      final d = JournalPrintData.from(
          journal: journal, attendance: rows, facilityName: '架空の事業所');
      expect(d.lines, [
        '業務日誌',
        '日付　2026年11月25日（水）',
        '事業所名　架空の事業所',
        '今日いた職員',
        '職員 冬子、佐藤',
        '利用者の入退室時間',
        '氏名',
        '入室',
        '退室',
        '状態',
        '架空 一郎',
        '14:00',
        '17:00',
        '退室済み',
        '架空 花子',
        '',
        '',
        '欠席（通院）',
        'その日の内容',
        '外遊び、設定から消した選択肢',
        '備考',
        '架空の備考',
        '記入者　職員 冬子　11月25日 18:05',
      ]);
    });

    test('出席管理で時刻を直すと、印刷の中身も直した時刻になる（日誌に時刻を写していない）', () {
      final fixed = [
        JournalAttendanceRow(
            customerId: 'c1',
            name: '架空 一郎',
            status: AttendanceStatus.departed,
            checkIn: at(14, 30),
            checkOut: at(17, 0)),
      ];
      final d = JournalPrintData.from(
          journal: journal, attendance: fixed, facilityName: '架空の事業所');
      expect(d.attendanceRows.single, ['架空 一郎', '14:30', '17:00', '退室済み']);
    });

    int pageCount(Uint8List bytes) => RegExp(r'/Type\s*/Page(?![s\w])')
        .allMatches(String.fromCharCodes(bytes))
        .length;

    Future<(pw.Font, pw.Font)> fonts() async {
      // 日本語のフォントを指定すれば使う（検証環境で文字を取り出して確かめる用）
      final path = Platform.environment['LINKDAY_PDF_FONT'];
      if (path != null && File(path).existsSync()) {
        final f = pw.Font.ttf(ByteData.sublistView(
            Uint8List.fromList(File(path).readAsBytesSync())));
        return (f, f);
      }
      return (pw.Font.helvetica(), pw.Font.helveticaBold());
    }

    test('PDF ができる。20 人分でも 1 日 1 枚', () async {
      final many = [
        for (var i = 0; i < 20; i++)
          JournalAttendanceRow(
              customerId: 'c$i',
              name: '架空 利用者$i',
              status: AttendanceStatus.departed,
              checkIn: at(14, i),
              checkOut: at(17, i)),
      ];
      final d = JournalPrintData.from(
          journal: journal.copyWith(note: '架空の備考。' * 40),
          attendance: many,
          facilityName: '架空の事業所');
      final (regular, bold) = await fonts();
      final bytes = await DailyJournalPdfService.buildPdf(d,
          regular: regular, bold: bold);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(pageCount(bytes), 1);
      final out = Platform.environment['LINKDAY_PDF_OUT'];
      if (out != null) File('$out/journal.pdf').writeAsBytesSync(bytes);
    });

    test('備考が非常に長いときは切らずに 2 枚目へ続ける', () async {
      final d = JournalPrintData.from(
          journal:
              journal.copyWith(note: List.filled(120, '架空の長い備考の行').join('\n')),
          attendance: rows,
          facilityName: '架空の事業所');
      final (regular, bold) = await fonts();
      final bytes = await DailyJournalPdfService.buildPdf(d,
          regular: regular, bold: bold);
      expect(pageCount(bytes), greaterThanOrEqualTo(2));
    });
  });
}
