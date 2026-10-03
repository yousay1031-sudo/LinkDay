import 'package:flutter_test/flutter_test.dart';

import 'package:linkday_app/services/google_maps_service.dart';

/// Day 10: API キー漏洩防止テスト
///
/// 【背景】
/// REST 版 Google Maps API はクエリ文字列に `key=AIza...` を含むため、
/// 通信例外（SocketException / ClientException）や API の error_message を
/// そのまま UI のスナックバーやログに流すと、API キーが平文で表示される。
/// 画面側は `'エラー: $e'` 形式で例外を表示しているため、
/// 例外文に含まれる時点で漏洩になる。
///
/// そのため [GoogleMapsService.maskApiKey] で必ずマスクする。
void main() {
  group('maskApiKey: API キーを平文で残さない', () {
    test('クエリ文字列の key= をマスクする', () {
      const raw =
          'https://maps.googleapis.com/maps/api/geocode/json?address=x&key=AIzaSyDUMMYTESTKEY0000000000000000000';
      final masked = GoogleMapsService.maskApiKey(raw);

      expect(masked, isNot(contains('AIzaSy')));
      expect(masked, contains('***REDACTED***'));
      // URL の他の部分は診断のため残る
      expect(masked, contains('geocode/json'));
    });

    test('key= が末尾でなく中間にある場合もマスクする', () {
      const raw = 'https://x/api?key=AIzaSyABCDEFGHIJKLMNOP123456&language=ja';
      final masked = GoogleMapsService.maskApiKey(raw);

      expect(masked, isNot(contains('AIzaSy')));
      expect(masked, contains('language=ja'), reason: '後続パラメータを消しすぎている');
    });

    test('URL でない生のキー文字列もマスクする', () {
      const raw =
          'ClientException: failed with key AIzaSyDUMMYTESTKEY0000000000000000000';
      final masked = GoogleMapsService.maskApiKey(raw);

      expect(masked, isNot(contains('AIzaSy')));
      expect(masked, contains('***REDACTED***'));
    });

    test('例外メッセージ全体を渡してもキーが残らない', () {
      // http パッケージの例外は URI 全体を含むことがある
      final e = Exception(
          'SocketException: Failed host lookup (uri=https://maps.googleapis.com/maps/api/directions/json?key=AIzaSyDUMMYKEY1234567890abc&origin=1,2)');
      final masked = GoogleMapsService.maskApiKey(e.toString());

      expect(masked, isNot(contains('AIzaSyDUMMYKEY')));
      expect(masked, isNot(matches(RegExp(r'AIza[0-9A-Za-z_\-]{10,}'))));
    });

    test('キーを含まない文字列は変更しない', () {
      const raw = 'APIクォータを超過しました';
      expect(GoogleMapsService.maskApiKey(raw), raw);
    });

    test('複数のキー出現をすべてマスクする', () {
      const raw =
          'key=AIzaSyAAAAAAAAAAAAAAAAAAAA retry key=AIzaSyBBBBBBBBBBBBBBBBBBBB';
      final masked = GoogleMapsService.maskApiKey(raw);

      expect(masked, isNot(contains('AIzaSyAAAA')));
      expect(masked, isNot(contains('AIzaSyBBBB')));
      expect(masked.split('***REDACTED***').length - 1, 2);
    });
  });
}
