import 'package:flutter_test/flutter_test.dart';
import 'package:linkday_app/verify/verify_config.dart';
import 'package:linkday_app/verify/verify_faults.dart';
import 'package:linkday_app/verify/verify_seed.dart';

void main() {
  group('VerifyConfig', () {
    test('通常ビルドでは無効（既定 false）', () {
      expect(VerifyConfig.enabled, isFalse);
    });
    test('demo- 以外・本番ID・外部ホストを拒否する', () {
      expect(VerifyConfig.validate(project: 'demo-linkday', host: '127.0.0.1',
          authPortOverride: 9099, firestorePortOverride: 8080), isEmpty);
      expect(VerifyConfig.validate(project: 'linkday-proud', host: '127.0.0.1',
          authPortOverride: 9099, firestorePortOverride: 8080), isNotEmpty);
      expect(VerifyConfig.validate(project: 'demo-x', host: '10.0.0.5',
          authPortOverride: 9099, firestorePortOverride: 8080), isNotEmpty);
      expect(VerifyConfig.validate(project: 'demo-x', host: 'localhost',
          authPortOverride: 9099, firestorePortOverride: 9099), isNotEmpty);
    });
  });

  group('VerifyFaults.parseFaults', () {
    test('空・null は空集合、カンマ区切りを分解する', () {
      expect(VerifyFaults.parseFaults(null), isEmpty);
      expect(VerifyFaults.parseFaults('  '), isEmpty);
      expect(VerifyFaults.parseFaults('attendance, weekly ,'),
          {'attendance', 'weekly'});
    });
  });

  group('VerifySeed', () {
    test('ダミー顧客は 50 件超で ID が一意、架空データのみ', () {
      expect(VerifySeed.customerCount, greaterThan(50));
      final now = DateTime(2026, 11, 15);
      final ids = <String>{};
      for (var n = 1; n <= VerifySeed.customerCount; n++) {
        final c = VerifySeed.buildCustomer(n, now);
        expect(c.id, startsWith(VerifySeed.idPrefix));
        ids.add(c.id);
        expect(c.name, isNotEmpty);
      }
      expect(ids.length, VerifySeed.customerCount);
    });
  });
}
