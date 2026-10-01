import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// ignore_for_file: implementation_imports
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/hive_impl.dart';

import 'package:linkday_app/models/customer.dart';
import 'package:linkday_app/models/geocode_candidate.dart';
import 'package:linkday_app/services/customer_service.dart';
import 'package:linkday_app/services/transport_location_resolver.dart';

/// Day 8: 送迎場所ジオコーディング
///   - Customer モデル往復（coords 含む save/load）
///   - 旧データ（HiveField 19-21 なし）読込の後方互換
///   - Resolver のロジック（自動採用 / 複数候補 / 失敗 / API 節約）
void main() {
  late Directory tmp;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('linkday_day8_');
    Hive.init(tmp.path);
    Hive.registerAdapter(CustomerAdapter());
    await CustomerService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  setUp(() async => Hive.box<Customer>('customers').clear());

  GeocodeCandidate cand(String addr, double lat, double lng, [List<String> types = const ['premise']]) =>
      GeocodeCandidate(formattedAddress: addr, lat: lat, lng: lng, types: types);

  // ── モデル ──────────────────────────────────────────────────

  group('Customer model', () {
    test('coords は transportLocations の長さに揃う（デフォルト null / unresolved）', () {
      final c = Customer(name: 'A', nameKana: 'ア', transportLocations: ['x', 'y', 'z']);
      expect(c.transportLocationLats, [null, null, null]);
      expect(c.transportLocationLngs, [null, null, null]);
      expect(c.transportLocationStatus, ['unresolved', 'unresolved', 'unresolved']);
      expect(c.transportCoord(0), isNull);
      expect(c.isTransportResolved(0), isFalse);
    });

    test('setTransportCoord / transportCoord / isTransportResolved', () {
      final c = Customer(name: 'A', nameKana: 'ア', transportLocations: ['x', 'y']);
      c.setTransportCoord(1, 42.9, 143.2, Customer.locManual);
      expect(c.transportCoord(1), (lat: 42.9, lng: 143.2));
      expect(c.isTransportResolved(1), isTrue);
      expect(c.isTransportResolved(0), isFalse);
      // failed は座標 null
      c.setTransportCoord(0, null, null, Customer.locFailed);
      expect(c.transportStatus(0), Customer.locFailed);
      expect(c.isTransportResolved(0), isFalse);
      // 範囲外アクセスは null / unresolved
      expect(c.transportCoord(5), isNull);
      expect(c.transportStatus(5), Customer.locUnresolved);
    });

    test('Hive 往復: coords / status が保存・復元される', () async {
      final c = Customer(
        id: 'rt',
        name: '往復',
        nameKana: 'オウフク',
        transportLocations: ['北海道帯広市東1条南3丁目', '帯広駅前'],
        transportLocationLats: [42.9238, 42.9177],
        transportLocationLngs: [143.1966, 143.2042],
        transportLocationStatus: [Customer.locResolved, Customer.locManual],
      );
      await CustomerService.instance.addCustomer(c);
      // box を閉じて再オープン（ディスク往復）
      await Hive.box<Customer>('customers').close();
      await CustomerService.instance.init();
      final r = CustomerService.instance.getCustomerById('rt')!;
      expect(r.transportLocationLats, [42.9238, 42.9177]);
      expect(r.transportLocationLngs, [143.1966, 143.2042]);
      expect(r.transportLocationStatus, ['resolved', 'manual']);
      expect(r.isTransportResolved(0), isTrue);
      expect(r.isTransportResolved(1), isTrue);
      // 既存フィールドも維持
      expect(r.transportLocations, ['北海道帯広市東1条南3丁目', '帯広駅前']);
    });

    test('後方互換: 旧フォーマット（field 19-21 なし）のバイナリを読める', () async {
      // 旧 CustomerAdapter (19 fields) と同じ形式で手書きシリアライズ
      final writer = _OldFormatWriter();
      final bytes = writer.writeOldCustomer(
        id: 'old-1',
        name: '旧 太郎',
        nameKana: 'キュウ タロウ',
        transportLocations: ['北海道帯広市西4条南10丁目', '緑ヶ丘公園前', '西帯広駅'],
      );
      final reader = BinaryReaderImpl(bytes, Hive as HiveImpl);
      final c = CustomerAdapter().read(reader);
      expect(c.id, 'old-1');
      expect(c.name, '旧 太郎');
      expect(c.transportLocations.length, 3);
      // 新フィールドはデフォルト補完
      expect(c.transportLocationLats, [null, null, null]);
      expect(c.transportLocationLngs, [null, null, null]);
      expect(c.transportLocationStatus, ['unresolved', 'unresolved', 'unresolved']);
      expect(c.isTransportResolved(0), isFalse);
      // そのまま保存 → 再読込できる（新フォーマット）
      await CustomerService.instance.addCustomer(c);
      final again = CustomerService.instance.getCustomerById('old-1')!;
      expect(again.transportLocationStatus.length, 3);
    });

    test('copyWith は coords を引き継ぐ', () {
      final c = Customer(name: 'A', nameKana: 'ア', transportLocations: ['x'],
          transportLocationLats: [1.0], transportLocationLngs: [2.0],
          transportLocationStatus: [Customer.locManual]);
      final d = c.copyWith(notes: 'n');
      expect(d.transportCoord(0), (lat: 1.0, lng: 2.0));
      expect(d.transportStatus(0), Customer.locManual);
    });
  });

  // ── GeocodeCandidate ─────────────────────────────────────────

  group('GeocodeCandidate', () {
    test('帯広 bounds 判定', () {
      expect(cand('帯広', 42.92, 143.20).isOutsideObihiroBounds, isFalse);
      expect(cand('札幌', 43.06, 141.35).isOutsideObihiroBounds, isTrue);
      expect(cand('東京', 35.68, 139.76).isOutsideObihiroBounds, isTrue);
    });
    test('typeLabel / isPointLevel', () {
      expect(cand('a', 0, 0, ['park', 'point_of_interest']).typeLabel, '公園');
      expect(cand('a', 0, 0, ['transit_station']).typeLabel, '駅・停留所');
      expect(cand('a', 0, 0, ['locality', 'political']).isPointLevel, isFalse);
      expect(cand('a', 0, 0, ['premise']).isPointLevel, isTrue);
    });
    test('fromJson / toJson 往復', () {
      final j = {'formattedAddress': 'X', 'lat': 1.5, 'lng': 2.5, 'placeId': 'p', 'types': ['park'], 'partialMatch': true};
      final c = GeocodeCandidate.fromJson(j);
      expect(c.toJson(), j);
    });
  });

  // ── Resolver ─────────────────────────────────────────────────

  group('TransportLocationResolver', () {
    test('isResolvable: 空・「なし」等は対象外', () {
      expect(TransportLocationResolver.isResolvable(''), isFalse);
      expect(TransportLocationResolver.isResolvable('  '), isFalse);
      expect(TransportLocationResolver.isResolvable('なし'), isFalse);
      expect(TransportLocationResolver.isResolvable('-'), isFalse);
      expect(TransportLocationResolver.isResolvable('帯広駅前'), isTrue);
    });

    test('候補1件 → 自動採用 resolved、永続化', () async {
      final c = Customer(id: 'c1', name: 'A', nameKana: 'ア', transportLocations: ['北海道帯広市東1条南3丁目']);
      await CustomerService.instance.addCustomer(c);
      final (o, r) = await TransportLocationResolver.instance.resolveOne(c, 0,
          fetch: (a) async => GeocodeCandidatesResult(address: a, candidates: [cand('帯広市東1条南3', 42.92, 143.20)]));
      expect(o, ResolveOutcome.autoAdopted);
      expect(r!.isSingle, isTrue);
      final saved = CustomerService.instance.getCustomerById('c1')!;
      expect(saved.transportStatus(0), Customer.locResolved);
      expect(saved.transportCoord(0), (lat: 42.92, lng: 143.20));
    });

    test('複数候補 → pendingSelection、status は変更しない', () async {
      final c = Customer(id: 'c2', name: 'B', nameKana: 'ビ', transportLocations: ['帯広駅前']);
      await CustomerService.instance.addCustomer(c);
      final (o, r) = await TransportLocationResolver.instance.resolveOne(c, 0,
          fetch: (a) async => GeocodeCandidatesResult(address: a, candidates: [
                cand('帯広駅前（北）', 42.9177, 143.2042, ['transit_station']),
                cand('帯広駅前（南）', 42.9160, 143.2040, ['bus_station']),
              ]));
      expect(o, ResolveOutcome.pendingSelection);
      expect(r!.candidates.length, 2);
      expect(CustomerService.instance.getCustomerById('c2')!.transportStatus(0), Customer.locUnresolved);
      // adopt → manual
      await TransportLocationResolver.instance.adoptCandidate(c, 0, r.candidates[1]);
      final saved = CustomerService.instance.getCustomerById('c2')!;
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.9160, lng: 143.2040));
    });

    test('0件 → failed / 例外 → failed', () async {
      final c = Customer(id: 'c3', name: 'C', nameKana: 'シ', transportLocations: ['存在しない場所', 'エラー']);
      await CustomerService.instance.addCustomer(c);
      final (o1, _) = await TransportLocationResolver.instance.resolveOne(c, 0,
          fetch: (a) async => GeocodeCandidatesResult(address: a, candidates: const []));
      expect(o1, ResolveOutcome.failed);
      final (o2, _) = await TransportLocationResolver.instance.resolveOne(c, 1,
          fetch: (a) async => throw Exception('network'));
      expect(o2, ResolveOutcome.failed);
      final saved = CustomerService.instance.getCustomerById('c3')!;
      expect(saved.transportLocationStatus, ['failed', 'failed']);
    });

    test('解決済みは API を呼ばない（alreadyResolved）、force で再取得', () async {
      int calls = 0;
      final c = Customer(id: 'c4', name: 'D', nameKana: 'デ', transportLocations: ['x'],
          transportLocationLats: [1.0], transportLocationLngs: [2.0],
          transportLocationStatus: [Customer.locManual]);
      await CustomerService.instance.addCustomer(c);
      Future<GeocodeCandidatesResult> f(String a) async {
        calls++;
        // 帯広市内・地点粒度 → 自動採用可
        return GeocodeCandidatesResult(address: a, candidates: [cand('x', 42.92, 143.20)]);
      }
      final (o, _) = await TransportLocationResolver.instance.resolveOne(c, 0, fetch: f);
      expect(o, ResolveOutcome.alreadyResolved);
      expect(calls, 0);
      final (o2, _) = await TransportLocationResolver.instance.resolveOne(c, 0, fetch: f, force: true);
      expect(o2, ResolveOutcome.autoAdopted);
      expect(calls, 1);
    });

    test('resolveAll: 進捗・サマリー・キュー・API節約', () async {
      final customers = [
        Customer(id: 'r1', name: '山田', nameKana: 'ヤマダ', transportLocations: ['帯広市東1条', '帯広駅前']),
        Customer(id: 'r2', name: '鈴木', nameKana: 'スズキ', transportLocations: ['帯広市西4条', 'なし']),
        Customer(id: 'r3', name: '田中', nameKana: 'タナカ', transportLocations: ['解決済'],
            transportLocationLats: [1.0], transportLocationLngs: [2.0],
            transportLocationStatus: [Customer.locResolved]),
        Customer(id: 'r4', name: '佐藤', nameKana: 'サトウ', transportLocations: ['不明地']),
      ];
      for (final c in customers) {
        await CustomerService.instance.addCustomer(c);
      }
      final called = <String>[];
      final progress = <int>[];
      final s = await TransportLocationResolver.instance.resolveAll(
        customers,
        interval: Duration.zero,
        onProgress: (p) => progress.add(p.done),
        fetch: (a) async {
          called.add(a);
          if (a == '北海道帯広市 帯広駅前') {
            return GeocodeCandidatesResult(address: a, candidates: [
              cand('A', 42.91, 143.20),
              cand('B', 42.92, 143.21),
            ]);
          }
          if (a == '北海道帯広市 不明地') {
            return GeocodeCandidatesResult(address: a, candidates: const []);
          }
          return GeocodeCandidatesResult(address: a, candidates: [cand(a, 42.9, 143.2)]);
        },
      );
      // 「なし」「解決済」は呼ばれない。「北海道」「帯広市」を含まない短名は補完される。
      expect(called, [
        '帯広市東1条',
        '北海道帯広市 帯広駅前',
        '帯広市西4条',
        '北海道帯広市 不明地',
      ]);
      expect(s.autoAdopted, 2);
      expect(s.pending, 1);
      expect(s.failed, 1);
      expect(s.alreadyResolved, 1);
      expect(s.apiCalls, 4);
      expect(s.pendingQueue.single.customer.id, 'r1');
      expect(s.pendingQueue.single.index, 1);
      expect(progress.last, 4);

      final st = TransportLocationResolver.countStatus(CustomerService.instance.getAllCustomers());
      expect(st.total, 5); // 「なし」は除外
      expect(st.resolved, 3);
      expect(st.failed, 1);
      expect(st.unresolved, 1);
    });

    test('countStatus に suspect（誤採用）件数が含まれる', () async {
      final ok = Customer(id: 's1', name: '正常', nameKana: 'セイジョウ',
          transportLocations: ['北海道帯広市西4条南10丁目'],
          transportLocationLats: [42.92], transportLocationLngs: [143.19],
          transportLocationStatus: [Customer.locResolved],
          transportLocationFormatted: ['北海道帯広市西4条南10丁目'],
          transportLocationTypes: ['street_address']);
      final bad = Customer(id: 's2', name: '誤採用', nameKana: 'ゴサイヨウ',
          transportLocations: ['南公園'],
          transportLocationLats: [34.95], transportLocationLngs: [137.17],
          transportLocationStatus: [Customer.locResolved],
          transportLocationFormatted: ['愛知県岡崎市 南公園'],
          transportLocationTypes: ['park']);
      await CustomerService.instance.addCustomer(ok);
      await CustomerService.instance.addCustomer(bad);
      final st = TransportLocationResolver.countStatus([ok, bad]);
      expect(st.resolved, 2);
      expect(st.suspect, 1);
    });

    test('clearCoord → unresolved', () async {
      final c = Customer(id: 'c5', name: 'E', nameKana: 'イ', transportLocations: ['x'],
          transportLocationLats: [1.0], transportLocationLngs: [2.0],
          transportLocationStatus: [Customer.locManual]);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance.clearCoord(c, 0);
      final saved = CustomerService.instance.getCustomerById('c5')!;
      expect(saved.transportStatus(0), Customer.locUnresolved);
      expect(saved.transportCoord(0), isNull);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // Day 8 修正: 誤ジオコード自動採用の防止
  // ════════════════════════════════════════════════════════════════

  /// 実機検証で誤採用された 6 件の再現候補（1 件目に返ってくる誤結果）
  ///   入力 → (formattedAddress, lat, lng, types)
  final badHits = <String, GeocodeCandidate>{
    // 愛知県岡崎市の南公園（bounds 外・park 粒度はあるが道外）
    '南公園': const GeocodeCandidate(
        formattedAddress: '愛知県岡崎市 南公園', lat: 34.9510, lng: 137.1730, types: ['park']),
    // 「日本」（国レベル重心）
    '西帯広小学校前': const GeocodeCandidate(
        formattedAddress: '日本', lat: 36.2048, lng: 138.2529, types: ['country', 'political']),
    '緑ヶ丘公園前': const GeocodeCandidate(
        formattedAddress: '日本', lat: 36.2048, lng: 138.2529, types: ['country', 'political']),
    // 福岡県中洲（bounds 外）
    '清流公園': const GeocodeCandidate(
        formattedAddress: '福岡県福岡市博多区中洲', lat: 33.5935, lng: 130.4055,
        types: ['park', 'point_of_interest']),
    // 宮崎県「デパート前」（bounds 外・部分一致）
    '藤丸百貨店前': const GeocodeCandidate(
        formattedAddress: '宮崎県宮崎市 デパート前', lat: 31.9111, lng: 131.4239,
        types: ['establishment'], partialMatch: true),
    // 「北海道帯広市」市全域重心（locality 粒度 = 粒度不足）
    '帯広駅前': const GeocodeCandidate(
        formattedAddress: '北海道帯広市', lat: 42.9238, lng: 143.1966,
        types: ['locality', 'political']),
  };

  group('修正1: 自動採用の厳格化', () {
    test('judgeAutoAdopt: 帯広市内・地点粒度・完全一致のみ自動採用可', () {
      final good = cand('北海道帯広市西4条南10丁目', 42.9177, 143.1966, ['street_address']);
      final j = TransportLocationResolver.judgeAutoAdopt(good);
      expect(j.allowed, isTrue);
      expect(j.reasons, isEmpty);
    });

    test('judgeAutoAdopt: bounds 外 → outsideBounds でブロック', () {
      final j = TransportLocationResolver.judgeAutoAdopt(badHits['南公園']!);
      expect(j.allowed, isFalse);
      expect(j.reasons, contains(AutoAdoptBlockReason.outsideBounds));
      expect(j.reasonText, contains('帯広市外'));
    });

    test('judgeAutoAdopt: formattedAddress が「日本」だけ → countryLevel でブロック', () {
      final j = TransportLocationResolver.judgeAutoAdopt(badHits['西帯広小学校前']!);
      expect(j.allowed, isFalse);
      expect(j.reasons, contains(AutoAdoptBlockReason.countryLevel));
      // bounds 外（長野県重心）でもあるため 2 理由
      expect(j.reasons, contains(AutoAdoptBlockReason.outsideBounds));
    });

    test('judgeAutoAdopt: types が country でなくても「日本」表記なら countryLevel', () {
      final j = TransportLocationResolver.judgeAutoAdopt(
          cand('日本', 42.92, 143.20, ['political']));
      expect(j.allowed, isFalse);
      expect(j.reasons, contains(AutoAdoptBlockReason.countryLevel));
    });

    test('judgeAutoAdopt: locality 粒度（市全域重心）→ coarseGranularity でブロック', () {
      final j = TransportLocationResolver.judgeAutoAdopt(badHits['帯広駅前']!);
      expect(j.allowed, isFalse);
      expect(j.reasons, contains(AutoAdoptBlockReason.coarseGranularity));
      expect(j.reasonText, contains('粒度不足'));
      expect(j.reasonText, contains('locality'));
      // bounds 内なので帯広市外理由は付かない
      expect(j.reasons, isNot(contains(AutoAdoptBlockReason.outsideBounds)));
    });

    test('judgeAutoAdopt: 県レベル（administrative_area_level_1）→ ブロック', () {
      final j = TransportLocationResolver.judgeAutoAdopt(
          cand('北海道', 43.06, 143.00, ['administrative_area_level_1', 'political']));
      expect(j.allowed, isFalse);
      expect(j.reasons, contains(AutoAdoptBlockReason.coarseGranularity));
    });

    test('judgeAutoAdopt: partialMatch → ブロック', () {
      final j = TransportLocationResolver.judgeAutoAdopt(const GeocodeCandidate(
          formattedAddress: '北海道帯広市 西帯広小学校',
          lat: 42.91, lng: 143.13, types: ['school'], partialMatch: true));
      expect(j.allowed, isFalse);
      expect(j.reasons, [AutoAdoptBlockReason.partialMatch]);
    });

    test('types 7 種（premise/park/transit_station/school/establishment'
        '/street_address/route）は粒度 OK', () {
      for (final t in [
        'premise', 'park', 'transit_station', 'school',
        'establishment', 'street_address', 'route',
      ]) {
        final j = TransportLocationResolver.judgeAutoAdopt(cand('帯広内', 42.92, 143.20, [t]));
        expect(j.allowed, isTrue, reason: '$t は自動採用可であるべき');
      }
    });

    test('受け入れ基準1: 誤採用6件すべてが「自動採用不可→キュー」に流れる', () async {
      final customers = <Customer>[];
      for (final entry in badHits.entries) {
        customers.add(Customer(
            id: 'bad_${entry.key}', name: entry.key, nameKana: 'テスト',
            transportLocations: [entry.key]));
      }
      for (final c in customers) {
        await CustomerService.instance.addCustomer(c);
      }
      final s = await TransportLocationResolver.instance.resolveAll(
        customers,
        interval: Duration.zero,
        fetch: (q) async {
          // 補完後クエリから元の入力を逆引き
          final key = badHits.keys.firstWhere((k) => q.contains(k));
          return GeocodeCandidatesResult(address: q, candidates: [badHits[key]!]);
        },
      );
      expect(s.autoAdopted, 0, reason: '1 件も自動採用されてはならない');
      expect(s.pending, 6);
      expect(s.blocked, 6, reason: '6 件すべてが自動採用不可でキュー入り');
      expect(s.pendingQueue.length, 6);
      for (final q in s.pendingQueue) {
        expect(q.isBlockedAutoAdopt, isTrue);
        expect(q.blockReasons, isNotEmpty);
      }
      // status は変更されない（unresolved のまま）= 誤座標が保存されない
      for (final c in customers) {
        final saved = CustomerService.instance.getCustomerById(c.id)!;
        expect(saved.transportStatus(0), Customer.locUnresolved);
        expect(saved.transportCoord(0), isNull);
      }
    });

    test('ブロックされた候補でも status は failed にしない（選択待ちのまま）', () async {
      final c = Customer(id: 'blk', name: 'B', nameKana: 'ビ', transportLocations: ['南公園']);
      await CustomerService.instance.addCustomer(c);
      final (o, r, j) = await TransportLocationResolver.instance.resolveOneDetailed(
        c, 0,
        fetch: (q) async =>
            GeocodeCandidatesResult(address: q, candidates: [badHits['南公園']!]),
      );
      expect(o, ResolveOutcome.pendingSelection);
      expect(r!.isSingle, isTrue);
      expect(j!.allowed, isFalse);
      final saved = CustomerService.instance.getCustomerById('blk')!;
      expect(saved.transportStatus(0), Customer.locUnresolved);
    });
  });

  group('修正2: 短名クエリの自動補完', () {
    test('「北海道」「帯広市」を含まない短名は「北海道帯広市 {入力}」に補完', () {
      expect(TransportLocationResolver.buildGeocodeQuery('南公園'), '北海道帯広市 南公園');
      expect(TransportLocationResolver.buildGeocodeQuery('西帯広小学校前'), '北海道帯広市 西帯広小学校前');
      expect(TransportLocationResolver.buildGeocodeQuery('緑ヶ丘公園前'), '北海道帯広市 緑ヶ丘公園前');
      expect(TransportLocationResolver.buildGeocodeQuery('清流公園'), '北海道帯広市 清流公園');
      expect(TransportLocationResolver.buildGeocodeQuery('藤丸百貨店前'), '北海道帯広市 藤丸百貨店前');
      expect(TransportLocationResolver.buildGeocodeQuery('帯広駅前'), '北海道帯広市 帯広駅前');
    });

    test('既に「北海道」または「帯広市」を含む場合は補完しない（住所系16件は不変）', () {
      const addrs = [
        '北海道帯広市西4条南10丁目',
        '北海道帯広市東1条南3丁目1-1',
        '帯広市西15条南35丁目',
        '北海道河西郡芽室町',
      ];
      for (final a in addrs) {
        expect(TransportLocationResolver.buildGeocodeQuery(a), a, reason: a);
        expect(TransportLocationResolver.needsQueryAugment(a), isFalse);
      }
    });

    test('前後空白は trim され、空文字は補完されない', () {
      expect(TransportLocationResolver.buildGeocodeQuery('  南公園  '), '北海道帯広市 南公園');
      expect(TransportLocationResolver.buildGeocodeQuery(''), '');
      expect(TransportLocationResolver.buildGeocodeQuery('   '), '');
    });

    test('resolveOne が補完後クエリで fetch を呼び、表示文字列は変更しない', () async {
      final c = Customer(id: 'aug', name: 'A', nameKana: 'ア', transportLocations: ['南公園']);
      await CustomerService.instance.addCustomer(c);
      String? received;
      await TransportLocationResolver.instance.resolveOne(c, 0, fetch: (q) async {
        received = q;
        // 補完後は帯広市内の公園が候補に出る（受け入れ基準2）
        return GeocodeCandidatesResult(address: q, candidates: [
          cand('北海道帯広市南町 南公園', 42.8871, 143.1920, ['park', 'point_of_interest']),
        ]);
      });
      expect(received, '北海道帯広市 南公園');
      // 表示上の元文字列は不変
      expect(c.transportLocations[0], '南公園');
      // 受け入れ基準2・4: 帯広市内の候補は自動採用できる
      final saved = CustomerService.instance.getCustomerById('aug')!;
      expect(saved.transportStatus(0), Customer.locResolved);
      expect(saved.transportCoord(0)!.lat, closeTo(42.8871, 0.0001));
    });

    test('補完後も0件なら failed（キュー対象外）', () async {
      final c = Customer(id: 'aug0', name: 'A', nameKana: 'ア', transportLocations: ['架空地名']);
      await CustomerService.instance.addCustomer(c);
      final (o, _) = await TransportLocationResolver.instance.resolveOne(c, 0,
          fetch: (q) async => GeocodeCandidatesResult(address: q, candidates: const []));
      expect(o, ResolveOutcome.failed);
    });

    test('補完後も自動採用不可ならキューへ', () async {
      final c = Customer(id: 'augb', name: 'A', nameKana: 'ア', transportLocations: ['帯広駅前']);
      await CustomerService.instance.addCustomer(c);
      final (o, _, j) = await TransportLocationResolver.instance.resolveOneDetailed(c, 0,
          fetch: (q) async =>
              GeocodeCandidatesResult(address: q, candidates: [badHits['帯広駅前']!]));
      expect(o, ResolveOutcome.pendingSelection);
      expect(j!.allowed, isFalse);
    });
  });

  group('修正3: 既存誤採用データの一括リセット', () {
    /// 実機で誤採用された 6 件 + 正しい住所系の採用を用意する
    Future<List<Customer>> seedMixed() async {
      final list = <Customer>[];
      // 誤採用 6 件（status=resolved、根拠メタ付き）
      final bads = <(String, String, double, double, List<String>)>[
        ('南公園', '愛知県岡崎市 南公園', 34.9510, 137.1730, ['park']),
        ('西帯広小学校前', '日本', 36.2048, 138.2529, ['country', 'political']),
        ('緑ヶ丘公園前', '日本', 36.2048, 138.2529, ['country', 'political']),
        ('清流公園', '福岡県福岡市博多区中洲', 33.5935, 130.4055, ['park']),
        ('藤丸百貨店前', '宮崎県宮崎市 デパート前', 31.9111, 131.4239, ['establishment']),
        ('帯広駅前', '北海道帯広市', 42.9238, 143.1966, ['locality', 'political']),
      ];
      for (int i = 0; i < bads.length; i++) {
        final (addr, fmt, lat, lng, types) = bads[i];
        list.add(Customer(
          id: 'mix_bad_$i', name: '誤$i', nameKana: 'ゴ',
          transportLocations: [addr],
          transportLocationLats: [lat], transportLocationLngs: [lng],
          transportLocationStatus: [Customer.locResolved],
          transportLocationFormatted: [fmt], transportLocationTypes: [types.join(',')],
        ));
      }
      // 正しい住所系の採用 16 件（受け入れ基準6: 影響を受けない）
      for (int i = 0; i < 16; i++) {
        list.add(Customer(
          id: 'mix_ok_$i', name: '正$i', nameKana: 'セイ',
          transportLocations: ['北海道帯広市西${i + 1}条南10丁目'],
          transportLocationLats: [42.9150 + i * 0.001],
          transportLocationLngs: [143.1900 + i * 0.001],
          transportLocationStatus: [Customer.locResolved],
          transportLocationFormatted: ['北海道帯広市西${i + 1}条南10丁目'],
          transportLocationTypes: ['street_address'],
        ));
      }
      // 実機の Hive には既に誤座標が保存済みなので、永続化層のガードを
      // 迂回して box に直接書き込み、「既存誤採用データ」を再現する。
      final box = Hive.box<Customer>('customers');
      for (final c in list) {
        await box.put(c.id, c);
      }
      return list;
    }

    test('受け入れ基準3: 対象件数が 6 件と事前表示される', () async {
      final list = await seedMixed();
      final suspects = TransportLocationResolver.findSuspectAdoptions(list);
      expect(suspects.length, 6);
      expect(suspects.map((s) => s.address).toSet(), {
        '南公園', '西帯広小学校前', '緑ヶ丘公園前', '清流公園', '藤丸百貨店前', '帯広駅前',
      });
      // 各件に理由が付く
      for (final s in suspects) {
        expect(s.reasons, isNotEmpty);
        expect(s.reasonText, isNotEmpty);
      }
    });

    test('受け入れ基準3: resetSuspectAdoptions で 6 件が unresolved に戻る', () async {
      final list = await seedMixed();
      final n = await TransportLocationResolver.instance.resetSuspectAdoptions(list);
      expect(n, 6);
      for (int i = 0; i < 6; i++) {
        final saved = CustomerService.instance.getCustomerById('mix_bad_$i')!;
        expect(saved.transportStatus(0), Customer.locUnresolved, reason: 'mix_bad_$i');
        expect(saved.transportCoord(0), isNull, reason: 'mix_bad_$i');
      }
      // 再実行は 0 件（冪等）
      final again = TransportLocationResolver.findSuspectAdoptions(
          CustomerService.instance.getAllCustomers());
      expect(again, isEmpty);
    });

    test('受け入れ基準6: 正しい住所系16件は影響を受けない', () async {
      final list = await seedMixed();
      await TransportLocationResolver.instance.resetSuspectAdoptions(list);
      for (int i = 0; i < 16; i++) {
        final saved = CustomerService.instance.getCustomerById('mix_ok_$i')!;
        expect(saved.transportStatus(0), Customer.locResolved, reason: 'mix_ok_$i');
        expect(saved.transportCoord(0), isNotNull, reason: 'mix_ok_$i');
        expect(saved.transportCoord(0)!.lat, closeTo(42.9150 + i * 0.001, 1e-9));
      }
      final st = TransportLocationResolver.countStatus(
          CustomerService.instance.getAllCustomers());
      expect(st.resolved, 16);
      expect(st.unresolved, 6);
      expect(st.suspect, 0);
    });

    test('手動採用（manual）は帯広市外でも解除対象にしない', () async {
      final c = Customer(id: 'man', name: '手動', nameKana: 'シュドウ',
          transportLocations: ['市外の指定地点'],
          transportLocationLats: [43.06], transportLocationLngs: [141.35],
          transportLocationStatus: [Customer.locManual],
          transportLocationFormatted: ['北海道札幌市'], transportLocationTypes: ['locality']);
      await CustomerService.instance.addCustomer(c);
      expect(TransportLocationResolver.findSuspectAdoptions([c]), isEmpty);
      final n = await TransportLocationResolver.instance.resetSuspectAdoptions([c]);
      expect(n, 0);
      expect(CustomerService.instance.getCustomerById('man')!.transportStatus(0),
          Customer.locManual);
    });

    test('根拠メタ無しの旧データは bounds のみで判定（帯広市内は温存）', () async {
      final inside = Customer(id: 'legacy_in', name: '旧内', nameKana: 'キュウ',
          transportLocations: ['帯広市内'],
          transportLocationLats: [42.92], transportLocationLngs: [143.20],
          transportLocationStatus: [Customer.locResolved]);
      final outside = Customer(id: 'legacy_out', name: '旧外', nameKana: 'キュウ',
          transportLocations: ['市外'],
          transportLocationLats: [34.95], transportLocationLngs: [137.17],
          transportLocationStatus: [Customer.locResolved]);
      await CustomerService.instance.addCustomer(inside);
      await CustomerService.instance.addCustomer(outside);
      final suspects = TransportLocationResolver.findSuspectAdoptions([inside, outside]);
      expect(suspects.length, 1);
      expect(suspects.single.customer.id, 'legacy_out');
    });
  });

  group('受け入れ基準5: 「日本」レベルの座標はどの経路でも保存されない', () {
    const japan = GeocodeCandidate(
        formattedAddress: '日本', lat: 36.2048, lng: 138.2529,
        types: ['country', 'political']);

    test('isStorableCandidate が false', () {
      expect(TransportLocationResolver.isStorableCandidate(japan), isFalse);
      expect(TransportLocationResolver.isStorableCandidate(
              cand('北海道帯広市南町 南公園', 42.88, 143.19, ['park'])),
          isTrue);
    });

    test('経路1: 一括解決（自動採用）では保存されない', () async {
      final c = Customer(id: 'j1', name: 'J1', nameKana: 'ジ', transportLocations: ['緑ヶ丘公園前']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance.resolveOne(c, 0,
          fetch: (q) async => GeocodeCandidatesResult(address: q, candidates: [japan]));
      final saved = CustomerService.instance.getCustomerById('j1')!;
      expect(saved.transportCoord(0), isNull);
      expect(saved.transportStatus(0), Customer.locUnresolved);
    });

    test('経路2: 手動採用（adoptCandidate）は拒否される', () async {
      final c = Customer(id: 'j2', name: 'J2', nameKana: 'ジ', transportLocations: ['西帯広小学校前']);
      await CustomerService.instance.addCustomer(c);
      final ok = await TransportLocationResolver.instance.adoptCandidate(c, 0, japan);
      expect(ok, isFalse);
      final saved = CustomerService.instance.getCustomerById('j2')!;
      expect(saved.transportCoord(0), isNull);
      expect(saved.transportStatus(0), Customer.locUnresolved);
    });

    test('経路3: 永続化層ガード（sanitizeCoords）が国レベル座標を破棄', () async {
      // Resolver を迂回して直接セットしても保存されない
      final c = Customer(id: 'j3', name: 'J3', nameKana: 'ジ', transportLocations: ['公園前']);
      c.setTransportCoord(0, 36.2048, 138.2529, Customer.locManual,
          formatted: '日本', types: const ['country', 'political']);
      await CustomerService.instance.addCustomer(c);
      final saved = CustomerService.instance.getCustomerById('j3')!;
      expect(saved.transportCoord(0), isNull);
      expect(saved.transportStatus(0), Customer.locUnresolved);
    });

    test('経路3: 「Japan」「日本国」表記も破棄される', () async {
      for (final (id, fmt) in [('j4', 'Japan'), ('j5', '日本国')]) {
        final c = Customer(id: id, name: id, nameKana: 'ジ', transportLocations: ['x']);
        c.setTransportCoord(0, 36.2, 138.2, Customer.locResolved,
            formatted: fmt, types: const ['political']);
        await CustomerService.instance.addCustomer(c);
        expect(CustomerService.instance.getCustomerById(id)!.transportCoord(0), isNull,
            reason: fmt);
      }
    });

    test('正しい帯広市内の座標は sanitize で消えない', () async {
      final c = Customer(id: 'j6', name: 'J6', nameKana: 'ジ', transportLocations: ['南公園']);
      final good = cand('北海道帯広市南町 南公園', 42.8871, 143.1920, ['park']);
      final ok = await TransportLocationResolver.instance.adoptCandidate(c, 0, good);
      expect(ok, isTrue);
      await CustomerService.instance.addCustomer(c);
      final saved = CustomerService.instance.getCustomerById('j6')!;
      expect(saved.transportCoord(0), (lat: 42.8871, lng: 143.1920));
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportFormatted(0), '北海道帯広市南町 南公園');
      expect(saved.transportTypes(0), ['park']);
    });
  });

  group('採用根拠メタ（field 22-23）', () {
    test('Hive 往復で formatted / types が保存・復元される', () async {
      final c = Customer(id: 'meta', name: 'M', nameKana: 'エム',
          transportLocations: ['南公園', '帯広駅前']);
      c.setTransportCoord(0, 42.8871, 143.1920, Customer.locResolved,
          formatted: '北海道帯広市南町 南公園', types: const ['park', 'point_of_interest']);
      await CustomerService.instance.addCustomer(c);
      await Hive.box<Customer>('customers').close();
      await CustomerService.instance.init();
      final r = CustomerService.instance.getCustomerById('meta')!;
      expect(r.transportFormatted(0), '北海道帯広市南町 南公園');
      expect(r.transportTypes(0), ['park', 'point_of_interest']);
      expect(r.hasTransportMeta(0), isTrue);
      expect(r.hasTransportMeta(1), isFalse);
    });

    test('旧データ（field 22-23 なし）はメタ無しで読める', () {
      final c = Customer(name: 'L', nameKana: 'エル', transportLocations: ['a', 'b']);
      expect(c.transportLocationFormatted, [null, null]);
      expect(c.transportLocationTypes, [null, null]);
      expect(c.transportTypes(0), isEmpty);
      expect(c.hasTransportMeta(0), isFalse);
    });

    test('copyWith はメタを引き継ぐ', () {
      final c = Customer(name: 'C', nameKana: 'シ', transportLocations: ['x']);
      c.setTransportCoord(0, 42.9, 143.2, Customer.locManual,
          formatted: 'F', types: const ['premise']);
      final d = c.copyWith(notes: 'n');
      expect(d.transportFormatted(0), 'F');
      expect(d.transportTypes(0), ['premise']);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // Day 8 追加改修: 地図から直接ピン指定（最終手段）
  // ════════════════════════════════════════════════════════════════

  group('初期位置決定ロジック（4分岐）', () {
    /// 帯広エリア bounds 内であること（受け入れ基準2: 日本全図から始まらない）
    void expectInsideObihiro(MapPinInitial p) {
      final c = GeocodeCandidate(formattedAddress: '', lat: p.lat, lng: p.lng);
      expect(c.isOutsideObihiroBounds, isFalse,
          reason: '初期位置は帯広エリア内であるべき: $p');
    }

    test('分岐1: 当該場所の採用済み座標を優先（ズーム16）', () {
      final c = Customer(name: 'A', nameKana: 'ア',
          transportLocations: ['場所1', '場所2'],
          transportLocationLats: [42.9100, 42.9500],
          transportLocationLngs: [143.1800, 143.2500],
          transportLocationStatus: [Customer.locManual, Customer.locResolved]);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 0,
          facilityLat: 42.9238, facilityLng: 143.1966);
      expect(p.source, PinInitialSource.ownCoord);
      expect(p.lat, 42.9100);
      expect(p.lng, 143.1800);
      expect(p.zoom, 16);
      expectInsideObihiro(p);
    });

    test('分岐2: 自分が未解決なら同一児童の他場所（場所1優先、ズーム15）', () {
      final c = Customer(name: 'B', nameKana: 'ビ',
          transportLocations: ['場所1', '場所2', '場所3'],
          transportLocationLats: [42.9100, 42.9500, null],
          transportLocationLngs: [143.1800, 143.2500, null],
          transportLocationStatus: [
            Customer.locResolved, Customer.locManual, Customer.locFailed,
          ]);
      // index 2（failed）→ 場所1（index 0）が選ばれる
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 2,
          facilityLat: 42.9238, facilityLng: 143.1966);
      expect(p.source, PinInitialSource.siblingCoord);
      expect(p.sourceIndex, 0, reason: '場所1 が優先されるべき');
      expect(p.lat, 42.9100);
      expect(p.zoom, 15);
      expectInsideObihiro(p);
      expect(p.sourceDescription, contains('送迎場所1'));
    });

    test('分岐2: 場所1が未解決なら次に解決済みの場所を使う', () {
      final c = Customer(name: 'B2', nameKana: 'ビ',
          transportLocations: ['場所1', '場所2', '場所3'],
          transportLocationLats: [null, 42.9500, null],
          transportLocationLngs: [null, 143.2500, null],
          transportLocationStatus: [
            Customer.locUnresolved, Customer.locManual, Customer.locUnresolved,
          ]);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 0,
          facilityLat: 42.9238, facilityLng: 143.1966);
      expect(p.source, PinInitialSource.siblingCoord);
      expect(p.sourceIndex, 1);
      expect(p.lat, 42.9500);
    });

    test('分岐3: 他場所が無ければ事業所座標（ズーム15）', () {
      final c = Customer(name: 'C', nameKana: 'シ', transportLocations: ['場所1']);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 0,
          facilityLat: 42.9238, facilityLng: 143.1966);
      expect(p.source, PinInitialSource.facility);
      expect(p.lat, 42.9238);
      expect(p.lng, 143.1966);
      expect(p.zoom, 15);
      expectInsideObihiro(p);
    });

    test('分岐4: 事業所座標も無ければ帯広市中心フォールバック（ズーム13）', () {
      final c = Customer(name: 'D', nameKana: 'デ', transportLocations: ['場所1']);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 0);
      expect(p.source, PinInitialSource.obihiroCenter);
      expect(p.lat, 42.9077437);
      expect(p.lng, 143.1996431);
      expect(p.zoom, 13);
      expectInsideObihiro(p);
    });

    test('分岐4: 事業所座標が片方 null でもフォールバックする', () {
      final c = Customer(name: 'D2', nameKana: 'デ', transportLocations: ['場所1']);
      for (final (fLat, fLng) in [(42.9238, null), (null, 143.1966)]) {
        final p = TransportLocationResolver.resolveInitialPinPosition(c, 0,
            facilityLat: fLat, facilityLng: fLng);
        expect(p.source, PinInitialSource.obihiroCenter);
      }
    });

    test('failed / unresolved でも必ず帯広エリア内の初期位置が返る（受け入れ基準1・2）', () {
      // geocode 0 件で failed になった状態（座標なし）
      final c = Customer(name: 'E', nameKana: 'イ',
          transportLocations: ['西帯広小学校前'],
          transportLocationStatus: [Customer.locFailed]);
      final withFacility = TransportLocationResolver.resolveInitialPinPosition(
          c, 0, facilityLat: 42.9238, facilityLng: 143.1966);
      final without = TransportLocationResolver.resolveInitialPinPosition(c, 0);
      expectInsideObihiro(withFacility);
      expectInsideObihiro(without);
      // 日本全図相当のズーム（<10）にならない
      expect(withFacility.zoom, greaterThanOrEqualTo(13));
      expect(without.zoom, greaterThanOrEqualTo(13));
    });

    test('座標はあるが status=failed の場合は自分の座標を使わない', () {
      // failed は座標 null 運用だが、万一残っていても採用済み扱いにしない
      final c = Customer(name: 'F', nameKana: 'エフ',
          transportLocations: ['場所1'],
          transportLocationLats: [42.80], transportLocationLngs: [143.00],
          transportLocationStatus: [Customer.locFailed]);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 0,
          facilityLat: 42.9238, facilityLng: 143.1966);
      expect(p.source, PinInitialSource.facility);
    });

    test('範囲外 index でもクラッシュせずフォールバックする', () {
      final c = Customer(name: 'G', nameKana: 'ジ', transportLocations: ['場所1']);
      final p = TransportLocationResolver.resolveInitialPinPosition(c, 5);
      expect(p.source, PinInitialSource.obihiroCenter);
    });

    test('PinInitialSource のラベルが全分岐で定義されている', () {
      for (final s in PinInitialSource.values) {
        expect(s.label, isNotEmpty);
      }
    });
  });

  group('手動ピン指定の保存（adoptManualCoord）', () {
    test('受け入れ基準3: status=manual で座標が Hive に保存される', () async {
      final c = Customer(id: 'pin1', name: 'P', nameKana: 'ピ',
          transportLocations: ['西帯広小学校前'],
          transportLocationStatus: [Customer.locFailed]);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance.adoptManualCoord(
          c, 0, 42.9015, 143.1452,
          formatted: '北海道帯広市西18条南2丁目');
      final saved = CustomerService.instance.getCustomerById('pin1')!;
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.9015, lng: 143.1452));
      expect(saved.transportFormatted(0), '北海道帯広市西18条南2丁目');
      expect(saved.transportTypes(0), ['premise']);
    });

    test('逆ジオコード失敗（null）でも座標は保存され「手動指定地点」になる', () async {
      final c = Customer(id: 'pin2', name: 'P2', nameKana: 'ピ',
          transportLocations: ['原野の集合場所']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.9500, 143.3000, formatted: null);
      final saved = CustomerService.instance.getCustomerById('pin2')!;
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.9500, lng: 143.3000));
      expect(saved.transportFormatted(0), TransportLocationResolver.manualPinLabel);
    });

    test('逆ジオコードが空文字を返しても「手動指定地点」になる', () async {
      final c = Customer(id: 'pin3', name: 'P3', nameKana: 'ピ',
          transportLocations: ['x']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.92, 143.20, formatted: '   ');
      expect(CustomerService.instance.getCustomerById('pin3')!.transportFormatted(0),
          TransportLocationResolver.manualPinLabel);
    });

    test('sanitizeManualLabel: 「日本」等の国レベル表記は手動指定地点に置換', () {
      expect(TransportLocationResolver.sanitizeManualLabel('日本'),
          TransportLocationResolver.manualPinLabel);
      expect(TransportLocationResolver.sanitizeManualLabel('日本国'),
          TransportLocationResolver.manualPinLabel);
      expect(TransportLocationResolver.sanitizeManualLabel('Japan'),
          TransportLocationResolver.manualPinLabel);
      expect(TransportLocationResolver.sanitizeManualLabel(null),
          TransportLocationResolver.manualPinLabel);
      // 通常の住所はそのまま
      expect(TransportLocationResolver.sanitizeManualLabel('北海道帯広市西4条南10丁目'),
          '北海道帯広市西4条南10丁目');
    });

    test('逆ジオコードが「日本」を返しても座標は破棄されない（sanitizeCoords 整合）', () async {
      final c = Customer(id: 'pin4', name: 'P4', nameKana: 'ピ',
          transportLocations: ['周辺に住所が無い地点']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.9800, 143.4000, formatted: '日本');
      final saved = CustomerService.instance.getCustomerById('pin4')!;
      // ユーザーが意図して置いたピンなので座標は残る
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.9800, lng: 143.4000));
      expect(saved.transportFormatted(0), TransportLocationResolver.manualPinLabel);
    });

    test('受け入れ基準: 帯広市外への手動配置は許可される（近隣町村への送迎）', () async {
      // 芽室町（帯広 bounds 外の近隣町村）
      final c = Customer(id: 'pin5', name: 'P5', nameKana: 'ピ',
          transportLocations: ['芽室町の集合場所']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.9100, 142.8000, formatted: '北海道河西郡芽室町');
      final saved = CustomerService.instance.getCustomerById('pin5')!;
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.9100, lng: 142.8000));
      // bounds 外であることを確認（それでも保存されている）
      expect(
          const GeocodeCandidate(formattedAddress: '', lat: 42.91, lng: 142.80)
              .isOutsideObihiroBounds,
          isTrue);
    });

    test('受け入れ基準4: 手動指定地点はリセット対象に含まれない', () async {
      // 帯広市外 + 逆ジオコード失敗という最も「疑わしい」条件でも対象外
      final c = Customer(id: 'pin6', name: 'P6', nameKana: 'ピ',
          transportLocations: ['芽室町の集合場所']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.9100, 142.8000, formatted: null);
      final saved = CustomerService.instance.getCustomerById('pin6')!;
      expect(TransportLocationResolver.findSuspectAdoptions([saved]), isEmpty);
      final n = await TransportLocationResolver.instance.resetSuspectAdoptions([saved]);
      expect(n, 0);
      expect(CustomerService.instance.getCustomerById('pin6')!.transportStatus(0),
          Customer.locManual);
      // countStatus でも suspect に数えられない
      final st = TransportLocationResolver.countStatus([saved]);
      expect(st.suspect, 0);
      expect(st.manual, 1);
    });

    test('手動ピンの types は premise（粒度不足判定に掛からない）', () {
      expect(TransportLocationResolver.manualPinTypes, ['premise']);
      const pseudo = GeocodeCandidate(
          formattedAddress: TransportLocationResolver.manualPinLabel,
          lat: 42.92, lng: 143.20,
          types: TransportLocationResolver.manualPinTypes);
      expect(pseudo.hasPointGranularity, isTrue);
      expect(pseudo.isCountryLevel, isFalse);
    });

    test('手動ピン後に地図で微調整しても manual のまま維持される（退行確認）', () async {
      final c = Customer(id: 'pin7', name: 'P7', nameKana: 'ピ',
          transportLocations: ['x']);
      await CustomerService.instance.addCustomer(c);
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.92, 143.20, formatted: '初回ピン');
      await TransportLocationResolver.instance
          .adoptManualCoord(c, 0, 42.93, 143.21, formatted: '微調整後');
      final saved = CustomerService.instance.getCustomerById('pin7')!;
      expect(saved.transportStatus(0), Customer.locManual);
      expect(saved.transportCoord(0), (lat: 42.93, lng: 143.21));
      expect(saved.transportFormatted(0), '微調整後');
    });
  });

  group('候補並び替え（帯広市内・地点粒度を優先）', () {
    test('sortedByPreference: 帯広市内の公園が「日本」「県外」より先に来る', () {
      final r = GeocodeCandidatesResult(address: '南公園', candidates: [
        cand('愛知県岡崎市 南公園', 34.95, 137.17, ['park']),
        cand('日本', 36.20, 138.25, ['country', 'political']),
        cand('北海道帯広市南町 南公園', 42.8871, 143.1920, ['park']),
        cand('北海道帯広市', 42.9238, 143.1966, ['locality', 'political']),
      ]);
      final sorted = r.sortedByPreference;
      expect(sorted.first.formattedAddress, '北海道帯広市南町 南公園');
      expect(sorted.last.formattedAddress, anyOf('日本', '愛知県岡崎市 南公園'));
    });

    test('preferenceScore: 帯広市内＋地点粒度＋完全一致が最大', () {
      final best = cand('北海道帯広市南町 南公園', 42.8871, 143.1920, ['park']);
      final worst = cand('日本', 36.20, 138.25, ['country']);
      expect(best.preferenceScore, greaterThan(worst.preferenceScore));
    });
  });
}

/// 旧 CustomerAdapter（HiveField 0〜18 のみ）と同一のバイナリを生成する
class _OldFormatWriter {
  Uint8List writeOldCustomer({
    required String id,
    required String name,
    required String nameKana,
    required List<String> transportLocations,
  }) {
    final w = BinaryWriterImpl(Hive as HiveImpl);
    final now = DateTime(2026, 1, 1);
    w
      ..writeByte(19)
      ..writeByte(0)
      ..write(id)
      ..writeByte(1)
      ..write(name)
      ..writeByte(2)
      ..write(nameKana)
      ..writeByte(3)
      ..write(null)
      ..writeByte(4)
      ..write('男児')
      ..writeByte(5)
      ..write(null)
      ..writeByte(6)
      ..write(null)
      ..writeByte(7)
      ..write(null)
      ..writeByte(8)
      ..write(null)
      ..writeByte(9)
      ..write('1234567890')
      ..writeByte(10)
      ..write(null)
      ..writeByte(11)
      ..write(23)
      ..writeByte(12)
      ..write(0)
      ..writeByte(13)
      ..write([1, 3, 5])
      ..writeByte(14)
      ..write(transportLocations)
      ..writeByte(15)
      ..write(null)
      ..writeByte(16)
      ..write(now)
      ..writeByte(17)
      ..write(now)
      ..writeByte(18)
      ..write(true);
    return w.toBytes();
  }
}
