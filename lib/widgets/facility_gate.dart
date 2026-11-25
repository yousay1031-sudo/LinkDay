import 'package:cloud_firestore/cloud_firestore.dart';
// Flutter 3.50 で material.dart 全体が非推奨（既存画面と同じ読み込みに揃える）
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/data_session.dart';
import '../screens/home_screen.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import 'auth_loading_screen.dart';

/// ログイン後に、所属事業所の確認と最初のデータ読み込みを済ませてから
/// ホーム画面を出すゲート。
///
///   resolving → 読み込み画面
///   notMember → 「事業所に登録されていません」＋ログアウト
///   error     → 理由＋再試行＋ログアウト
///   ready     → HomeScreen
class FacilityGate extends StatefulWidget {
  const FacilityGate({super.key, required this.uid, this.db, this.claim});

  final String uid;

  /// テスト用の保存先（省略時は FirebaseFirestore.instance）
  @visibleForTesting
  final FirebaseFirestore? db;

  /// テスト用: 所属を作ってもらう処理（省略時、Google でログインしたアカウントなら
  /// Cloud Functions の claimStaffMembership を呼ぶ）
  @visibleForTesting
  final Future<bool> Function()? claim;

  @override
  State<FacilityGate> createState() => _FacilityGateState();
}

class _FacilityGateState extends State<FacilityGate> {
  DataSessionStatus _lastStatus = DataSession.instance.status;

  @override
  void initState() {
    super.initState();
    DataSession.instance.addListener(_onStatusChanged);
    _startAfterBuild();
  }

  @override
  void dispose() {
    DataSession.instance.removeListener(_onStatusChanged);
    super.dispose();
  }

  /// 使える状態（ready）から外れたら、上に開いている画面・ダイアログを閉じる。
  ///
  /// このゲートは最初の画面の中にあるため、職員管理などを開いたまま
  /// 在籍終了・ログイン停止で「事業所に登録されていません」に切り替わっても、
  /// 上に重なった画面に隠れて見えなかった（2026-11-25 検証環境で確認）。
  void _onStatusChanged() {
    final now = DataSession.instance.status;
    final wasReady = _lastStatus == DataSessionStatus.ready;
    _lastStatus = now;
    if (!wasReady || now == DataSessionStatus.ready) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.maybeOf(context)?.popUntil((r) => r.isFirst);
    });
  }

  @override
  void didUpdateWidget(covariant FacilityGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _startAfterBuild();
  }

  /// start() はその場で状態変化を通知する。画面の組み立て中に通知すると、
  /// 上位の担当者帯（StaffBarScope）が更新されないことがある
  /// （再読み込み直後に帯が出なかった不具合）。組み立てが終わってから始める。
  void _startAfterBuild() {
    final uid = widget.uid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.uid != uid) return;
      // テスト（保存先の差し替えあり）では Firebase の認証に触れない
      final claim = widget.claim ??
          (widget.db == null && AuthService.instance.isGoogleUser
              ? AuthService.instance.claimMembership
              : null);
      DataSession.instance.start(uid, db: widget.db, claim: claim);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DataSession.instance,
      builder: (context, _) {
        final s = DataSession.instance;
        switch (s.status) {
          case DataSessionStatus.ready:
            return const HomeScreen();
          case DataSessionStatus.notMember:
            return const _GateMessage(
              key: Key('facilityGateNotMember'),
              icon: Icons.domain_disabled,
              title: 'このアカウントは事業所に登録されていません',
              body: '管理者に、このアカウントを事業所に登録するよう依頼してください。\n'
                  'Google でログインした場合は、管理者が職員管理でこのメールアドレスを'
                  '登録し、ログインを許可すると入れます（在籍終了・ログインを停止された'
                  '場合も、この画面になります）。',
              showRetry: false,
            );
          case DataSessionStatus.error:
            return _GateMessage(
              key: const Key('facilityGateError'),
              icon: Icons.cloud_off,
              title: 'データを読み込めませんでした',
              body: s.message ?? '通信状態を確かめて再試行してください。',
              showRetry: true,
            );
          case DataSessionStatus.idle:
          case DataSessionStatus.resolving:
            return const AuthLoadingScreen();
        }
      },
    );
  }
}

class _GateMessage extends StatelessWidget {
  const _GateMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.showRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool showRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 56, color: AppColors.warning),
                  const SizedBox(height: 16),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.6)),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (showRetry)
                        ElevatedButton.icon(
                          key: const Key('facilityGateRetry'),
                          onPressed: () => DataSession.instance.retry(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('再試行'),
                        ),
                      OutlinedButton.icon(
                        key: const Key('facilityGateSignOut'),
                        onPressed: () async {
                          await DataSession.instance.stop();
                          await AuthService.instance.signOut();
                        },
                        icon: const Icon(Icons.logout),
                        label: const Text('ログアウト'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
