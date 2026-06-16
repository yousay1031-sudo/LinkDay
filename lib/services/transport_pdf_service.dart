import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/transport_plan.dart';
import 'settings_service.dart';

/// 送迎ルート表 PDF 出力サービス（A4縦）
class TransportPdfService {
  TransportPdfService._();
  static final TransportPdfService instance = TransportPdfService._();

  /// 指定日の送迎ルート表 PDF を印刷プレビューで開く
  Future<void> printTransportSheet(
    String dateKey,
    List<TransportVehicleRoute> routes,
  ) async {
    final doc = await _buildDocument(dateKey, routes);
    await Printing.layoutPdf(
      onLayout: (format) async => doc.save(),
      name: '送迎ルート表_$dateKey.pdf',
    );
  }

  Future<pw.Document> _buildDocument(
    String dateKey,
    List<TransportVehicleRoute> routes,
  ) async {
    final doc = pw.Document();
    final settings = SettingsService.instance.getSettings();

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final boldFont = await PdfGoogleFonts.notoSansJPBold();

    final baseStyle = pw.TextStyle(font: font, fontSize: 9);
    final boldStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 9,
      fontWeight: pw.FontWeight.bold,
    );
    final titleStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 14,
      fontWeight: pw.FontWeight.bold,
    );
    final headerStyle = pw.TextStyle(
      font: boldFont,
      fontSize: 8,
      fontWeight: pw.FontWeight.bold,
    );

    // 日付を日本語表示
    final date = DateTime.tryParse(dateKey) ?? DateTime.now();
    final dateJP = DateFormat('yyyy年M月d日(E)', 'ja').format(date);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        build: (context) {
          final widgets = <pw.Widget>[
            // タイトル
            pw.Center(child: pw.Text('送迎ルート表', style: titleStyle)),
            pw.SizedBox(height: 6),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('事業所: ${settings.facilityName}', style: baseStyle),
                pw.Text('日付: $dateJP', style: baseStyle),
                pw.Text('出力: ${_today()}', style: baseStyle),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Divider(thickness: 0.5),
            pw.SizedBox(height: 8),
          ];

          // お迎え・お送りをセクションで分ける
          final pickups =
              routes.where((r) => r.transportType == TransportType.pickup).toList();
          final dropoffs =
              routes.where((r) => r.transportType == TransportType.dropoff).toList();

          if (pickups.isNotEmpty) {
            widgets.add(_sectionHeader('【お迎え】', boldStyle));
            widgets.add(pw.SizedBox(height: 4));
            for (final route in pickups) {
              widgets.addAll(_buildRouteBlock(route, baseStyle, boldStyle, headerStyle));
              widgets.add(pw.SizedBox(height: 10));
            }
          }

          if (dropoffs.isNotEmpty) {
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(_sectionHeader('【お送り】', boldStyle));
            widgets.add(pw.SizedBox(height: 4));
            for (final route in dropoffs) {
              widgets.addAll(_buildRouteBlock(route, baseStyle, boldStyle, headerStyle));
              widgets.add(pw.SizedBox(height: 10));
            }
          }

          return widgets;
        },
      ),
    );
    return doc;
  }

  pw.Widget _sectionHeader(String title, pw.TextStyle style) {
    return pw.Container(
      color: PdfColors.blueGrey200,
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: pw.Text(title, style: style),
    );
  }

  List<pw.Widget> _buildRouteBlock(
    TransportVehicleRoute route,
    pw.TextStyle baseStyle,
    pw.TextStyle boldStyle,
    pw.TextStyle headerStyle,
  ) {
    final widgets = <pw.Widget>[];

    // 車両ヘッダー
    widgets.add(
      pw.Container(
        color: PdfColors.orange50,
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: pw.Row(
          children: [
            pw.Text(route.vehicleName, style: boldStyle),
            pw.SizedBox(width: 16),
            pw.Text(
              '${route.passengerCount}名 / ${route.capacity}名',
              style: baseStyle,
            ),
            pw.Spacer(),
            pw.Text(
              '総距離: ${route.totalDistanceLabel}  '
              '所要時間: ${route.totalDurationLabel}',
              style: baseStyle,
            ),
          ],
        ),
      ),
    );
    widgets.add(pw.SizedBox(height: 3));

    if (route.stops.isEmpty) {
      widgets.add(pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text('停留所なし', style: baseStyle),
      ));
      return widgets;
    }

    // ルートテーブル
    final settings = SettingsService.instance.getSettings();
    final facilityName = settings.facilityName;
    // お迎え: 事業所(出発) → 停留所1 → 停留所2 ... → 事業所(到着)
    // お送り: 事業所(出発) → 停留所1 → 停留所2 ... → 最終停留所
    final rows = <pw.TableRow>[];

    // ヘッダー行
    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.blueGrey100),
      children: [
        _cell('#', headerStyle),
        _cell('利用者', headerStyle),
        _cell('住所', headerStyle),
        _cell('予定時刻', headerStyle),
        _cell('前停留所から', headerStyle),
      ],
    ));

    // 出発点（事業所）
    if (route.transportType == TransportType.dropoff) {
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.orange50),
        children: [
          _cell('出発', boldStyle),
          _cell(facilityName, boldStyle),
          _cell(settings.facilityAddress, baseStyle),
          _cell(settings.defaultPickupStart, baseStyle),
          _cell('—', baseStyle),
        ],
      ));
    }

    // 各停留所
    for (int i = 0; i < route.stops.length; i++) {
      final stop = route.stops[i];
      final rowColor =
          i.isEven ? PdfColors.white : PdfColors.grey50;
      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: rowColor),
        children: [
          _cell('${i + 1}', baseStyle),
          _cell(stop.customerName, boldStyle),
          _cell(stop.address.isEmpty ? '住所未設定' : stop.address, baseStyle),
          _cell(stop.scheduledTime ?? '—', baseStyle),
          _cell(
            stop.distanceFromPrevMeters != null
                ? '${stop.distanceLabel} / ${stop.durationLabel}'
                : '—',
            baseStyle,
          ),
        ],
      ));
    }

    // 到着点（事業所）お迎えの場合
    if (route.transportType == TransportType.pickup) {
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.orange50),
        children: [
          _cell('着', boldStyle),
          _cell(facilityName, boldStyle),
          _cell(settings.facilityAddress, baseStyle),
          _cell('—', baseStyle),
          _cell('—', baseStyle),
        ],
      ));
    }

    widgets.add(pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(30),
        1: pw.FlexColumnWidth(1.5),
        2: pw.FlexColumnWidth(3),
        3: pw.FixedColumnWidth(55),
        4: pw.FlexColumnWidth(1.5),
      },
      children: rows,
    ));

    // Google Maps URL
    if (route.googleMapsUrl != null) {
      widgets.add(pw.SizedBox(height: 2));
      widgets.add(pw.Text(
        'ナビ: ${route.googleMapsUrl}',
        style: pw.TextStyle(
          font: baseStyle.font,
          fontSize: 6.5,
          color: PdfColors.blue700,
        ),
      ));
    }

    return widgets;
  }

  pw.Widget _cell(String text, pw.TextStyle style) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      child: pw.Text(text, style: style, overflow: pw.TextOverflow.clip),
    );
  }

  String _today() {
    return DateFormat('yyyy/M/d HH:mm').format(DateTime.now());
  }
}
