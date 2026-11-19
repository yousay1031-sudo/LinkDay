import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'verify_auth_guard.dart';
import 'verify_config.dart';

/// 検証構成の Firebase 初期化と、起動前の到達確認。
///
/// 【本番へフォールバックしない】
/// - 設定が不正、またはエミュレータに到達できない場合は例外ではなく
///   [VerifyFailureApp]（赤い失敗画面）を出して起動を止める。
/// - Firebase.initializeApp には demo プロジェクト専用の [FirebaseOptions] を渡す。
///   本番の DefaultFirebaseOptions は検証構成から参照されない。
class VerifyBootstrap {
  VerifyBootstrap._();

  /// 起動前チェック。問題があればメッセージ（なければ null）。
  static Future<String?> preflight() async {
    final problems = VerifyConfig.validate();
    if (problems.isNotEmpty) {
      return '検証構成の設定が不正です。\n- ${problems.join('\n- ')}';
    }
    const host = VerifyConfig.emulatorHost;
    final auth = await _probe(
      Uri.http('$host:${VerifyConfig.authPort}', '/'),
      expectContains: 'authEmulator',
    );
    final fs = await _probe(
      Uri.http('$host:${VerifyConfig.firestorePort}', '/'),
      expectContains: 'Ok',
    );
    final msgs = <String>[
      if (!auth)
        'Auth エミュレータ($host:${VerifyConfig.authPort}) に到達できません',
      if (!fs)
        'Firestore エミュレータ($host:${VerifyConfig.firestorePort}) に到達できません',
    ];
    if (msgs.isEmpty) return null;
    return '${msgs.join('\n')}\n\n'
        'tool/verify/start_emulators.sh でエミュレータを起動してください。\n'
        '本番へは接続しません（フォールバックなし）。';
  }

  static Future<bool> _probe(Uri uri, {required String expectContains}) async {
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      return res.statusCode == 200 && res.body.contains(expectContains);
    } catch (e) {
      debugPrint('[Verify] probe failed: $uri ($e)');
      return false;
    }
  }

  /// demo プロジェクトで Firebase を初期化し、Auth / Firestore をエミュレータへ向ける。
  ///
  /// 問題があればメッセージを返す（呼び出し側は [VerifyFailureApp] を出して止める）。
  static Future<String?> initFirebase() async {
    const host = VerifyConfig.emulatorHost;
    // Web: Auth が作られた直後（保存済みログインの確認通信より前）にエミュレータへ
    // 向ける。initializeApp の後の useAuthEmulator だけでは間に合わない
    // （verify_auth_guard.dart の説明を参照）。
    if (kIsWeb &&
        !VerifyAuthGuard.install('http://$host:${VerifyConfig.authPort}')) {
      return 'Auth をエミュレータへ向ける準備ができませんでした。\n'
          '本番へは接続しません（フォールバックなし）。';
    }
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'demo-api-key',
        appId: '1:000000000000:web:0000000000000000000000',
        messagingSenderId: '000000000000',
        projectId: VerifyConfig.projectId,
        authDomain: '${VerifyConfig.projectId}.firebaseapp.com',
      ),
    );
    if (kIsWeb && !VerifyAuthGuard.connected) {
      return 'Auth をエミュレータへ向けられませんでした（初期化の順序を確認できません）。\n'
          '本番へは接続しません（フォールバックなし）。';
    }
    await FirebaseAuth.instance.useAuthEmulator(host, VerifyConfig.authPort);
    FirebaseFirestore.instance
        .useFirestoreEmulator(host, VerifyConfig.firestorePort);
    // Functions（LINE 送信）は呼び出し側でも遮断しているが、念のため
    // ループバックの未起動ポートへ向ける（外部の cloudfunctions.net へ出ない）。
    FirebaseFunctions.instanceFor(region: 'asia-northeast1')
        .useFunctionsEmulator(host, 5001);
    debugPrint('[Verify] Firebase = ${VerifyConfig.projectId} / '
        'auth=$host:${VerifyConfig.authPort} '
        'firestore=$host:${VerifyConfig.firestorePort}');
    return null;
  }
}

/// 検証構成の起動失敗画面。通常のアプリ画面へは進まない。
class VerifyFailureApp extends StatelessWidget {
  const VerifyFailureApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LinkDay [検証] 起動失敗',
      home: Scaffold(
        backgroundColor: const Color(0xFFFFEBEE),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('検証構成を開始できません',
                        key: Key('verifyFailureTitle'),
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    SelectableText(message),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 検証構成であることを常に示す細い帯（操作を妨げない）。
class VerifyStrip extends StatelessWidget {
  const VerifyStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: child),
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 3,
          child: IgnorePointer(
            child: ColoredBox(
              key: Key('verifyStrip'),
              color: Color(0xFFD81B60),
            ),
          ),
        ),
      ],
    );
  }
}
