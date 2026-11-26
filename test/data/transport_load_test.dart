import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:linkday_app/models/transport_load.dart';
import 'package:linkday_app/models/transport_plan.dart';
import 'package:linkday_app/services/transport_pdf_service.dart';
import 'package:pdf/widgets.dart' as pw;

/// 送迎計画: 車の乗車状況・定員超過・車が足りないときの注意（画面と印刷で同じ計算）
void main() {
  TransportStop stop(String id) =>
      TransportStop(customerId: id, customerName: '送迎 $id', address: '帯広市テスト');
  TransportVehicleRoute route(
          TransportType type, int index, int capacity, List<String> ids) =>
      TransportVehicleRoute(
        vehicleName: '車両$index',
        vehicleIndex: index,
        transportType: type,
        dateKey: '2026-12-02',
        capacity: capacity,
        stops: [for (final id in ids) stop(id)],
      );
  List<String> ids(String p, int n) => [for (var i = 0; i < n; i++) '$p$i'];

  test('定員を超えた人数・ちょうど定員・余裕あり', () {
    final over = RouteLoad.of(route(TransportType.pickup, 0, 6, ids('a', 13)));
    expect(over.riding, 13);
    expect(over.over, 7);
    expect(over.countLabel, '13/6名');
    expect(over.overLabel, '定員超過 7名');
    expect(over.full, isFalse);
    final full = RouteLoad.of(route(TransportType.pickup, 0, 6, ids('a', 6)));
    expect(full.over, 0);
    expect(full.overLabel, isNull);
    expect(full.full, isTrue);
    final room = RouteLoad.of(route(TransportType.pickup, 0, 6, ids('a', 4)));
    expect(room.full, isFalse);
    expect(room.overLabel, isNull);
  });

  test('注意: 車が足りない（合計の定員を超える）・足りるが定員を超えた車がある・問題なし', () {
    final short = [
      route(TransportType.pickup, 0, 6, ids('a', 13)),
      route(TransportType.dropoff, 0, 6, ids('a', 6)),
    ];
    expect(TransportShortage.notes(short), ['お迎え：車が足りません。乗れない人数 7名']);
    final unbalanced = [
      route(TransportType.dropoff, 0, 6, ids('a', 8)),
      route(TransportType.dropoff, 1, 6, ids('b', 2)),
    ];
    expect(TransportShortage.notes(unbalanced), ['お送り：定員を超えている車があります（2名）']);
    expect(
        TransportShortage.notes(
            [route(TransportType.pickup, 0, 6, ids('a', 6))]),
        isEmpty);
  });

  test('お休みの児童は乗る人数に入れず、何人含まれているかを数える', () {
    final r = route(TransportType.pickup, 0, 6, ids('a', 8));
    final load = RouteLoad.of(r, absentIds: {'a1', 'a5', 'zz'});
    expect(load.riding, 6);
    expect(load.absent, 2);
    expect(load.overLabel, isNull);
    expect(load.full, isTrue);
    // 注意もお休みを除いた人数で決める
    expect(TransportShortage.notes([r]), ['お迎え：車が足りません。乗れない人数 2名']);
    expect(TransportShortage.notes([r], absentIds: {'a1', 'a5'}), isEmpty);
  });

  group('印刷', () {
    setUpAll(() => initializeDateFormatting('ja'));
    Future<(pw.Font, pw.Font)> fonts() async {
      final path = Platform.environment['LINKDAY_PDF_FONT'];
      if (path != null && File(path).existsSync()) {
        final f = pw.Font.ttf(ByteData.sublistView(
            Uint8List.fromList(File(path).readAsBytesSync())));
        return (f, f);
      }
      return (pw.Font.helvetica(), pw.Font.helveticaBold());
    }

    test('定員を超えた車・車が足りない日も PDF が作れる', () async {
      final (r, b) = await fonts();
      final bytes = await TransportPdfService.buildPdf(
          '2026-12-02',
          [
            route(TransportType.pickup, 0, 6, ids('a', 13)),
            route(TransportType.dropoff, 0, 6, ids('a', 13)),
          ],
          regular: r,
          bold: b);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final out = Platform.environment['LINKDAY_PDF_OUT'];
      if (out != null) File('$out/transport.pdf').writeAsBytesSync(bytes);
    });
  });
}
