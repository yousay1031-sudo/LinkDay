// File generated manually for LinkDay project.
// Firebase project: linkday-proud
//
// DO NOT EDIT — このファイルはFirebaseプロジェクト設定から生成されています。
// 次回以降はFlutterFire CLIで再生成してください：
//   flutterfire configure

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// LinkDay アプリのデフォルトFirebase設定
///
/// 使い方：
/// ```dart
/// import 'firebase_options.dart';
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  DefaultFirebaseOptions._();

  /// 現在のプラットフォームに対応した FirebaseOptions を返す
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // TODO: google-services.json から android 設定を追加する
        throw UnsupportedError(
          'Android は未設定です。google-services.json を追加し、'
          'flutterfire configure を実行してください。',
        );
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'iOS は未設定です。GoogleService-Info.plist を追加し、'
          'flutterfire configure を実行してください。',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError('macOS は現在サポートしていません。');
      case TargetPlatform.windows:
        throw UnsupportedError('Windows は現在サポートしていません。');
      case TargetPlatform.linux:
        throw UnsupportedError('Linux は現在サポートしていません。');
      default:
        throw UnsupportedError(
          '不明なプラットフォームです: $defaultTargetPlatform',
        );
    }
  }

  /// Web プラットフォーム用 Firebase 設定
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAKpGd19e1eqgHGKWhBqgsuDpjBFSIHMaQ',
    authDomain: 'linkday-proud.firebaseapp.com',
    projectId: 'linkday-proud',
    storageBucket: 'linkday-proud.firebasestorage.app',
    messagingSenderId: '589307057451',
    appId: '1:589307057451:web:b7f5507ce6b47098b8a16e',
    measurementId: 'G-F3S5YXPVPR',
  );
}
