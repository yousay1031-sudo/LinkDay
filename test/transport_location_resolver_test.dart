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
        return GeocodeCandidatesResult(address: a, candidates: [cand('x', 9, 9)]);
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
          if (a == '帯広駅前') {
            return GeocodeCandidatesResult(address: a, candidates: [cand('A', 1, 1), cand('B', 2, 2)]);
          }
          if (a == '不明地') return GeocodeCandidatesResult(address: a, candidates: const []);
          return GeocodeCandidatesResult(address: a, candidates: [cand(a, 42.9, 143.2)]);
        },
      );
      expect(called, ['帯広市東1条', '帯広駅前', '帯広市西4条', '不明地']); // 「なし」「解決済」は呼ばれない
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
