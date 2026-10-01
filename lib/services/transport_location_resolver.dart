import 'package:flutter/foundation.dart';

import '../models/customer.dart';
import '../models/geocode_candidate.dart';
import 'customer_service.dart';

/// 候補取得関数（本番は MapsJsService.geocodeCandidates、テストでは差し替え）
typedef CandidateFetcher = Future<GeocodeCandidatesResult> Function(String address);

/// 一括解決の 1 件分の結果種別
enum ResolveOutcome {
  autoAdopted, // 候補 1 件 → resolved
  pendingSelection, // 複数候補 → ユーザー選択待ち
  failed, // 0 件 or API エラー → failed
  skippedEmpty, // 空文字・「なし」等 → 対象外
  alreadyResolved, // 既に resolved/manual → API 未呼び出し
}

/// 選択待ちキューの 1 件
class PendingSelection {
  final Customer customer;
  final int index; // 送迎場所 index 0..2
  final String address;
  final List<GeocodeCandidate> candidates;

  const PendingSelection({
    required this.customer,
    required this.index,
    required this.address,
    required this.candidates,
  });
}

/// 一括解決の進捗
class ResolveProgress {
  final int done;
  final int total;
  final Customer? current;
  final int? currentIndex;
  const ResolveProgress({
    required this.done,
    required this.total,
    this.current,
    this.currentIndex,
  });
}

/// 一括解決のサマリー
class ResolveSummary {
  int autoAdopted = 0;
  int pending = 0;
  int failed = 0;
  int skipped = 0;
  int alreadyResolved = 0;
  final List<PendingSelection> pendingQueue = [];
  final List<(Customer, int, String)> failures = []; // (customer, index, reason)

  int get apiCalls => autoAdopted + pending + failed;
}

/// 送迎場所ジオコーディング解決サービス（Day 8）
///
/// - 採用済み座標（resolved / manual）は API を呼ばない
/// - 候補 1 件 → 自動採用（status=resolved）
/// - 複数候補 → PendingSelection としてキューへ（status は変更しない）
/// - 0 件 / エラー → status=failed
class TransportLocationResolver {
  TransportLocationResolver._();
  static final TransportLocationResolver instance = TransportLocationResolver._();

  /// 解決対象外とみなす文字列
  static const Set<String> _ignoredValues = {
    '', 'なし', '無し', '-', '－', '—', 'ー', '未定', 'TBD', 'N/A', 'n/a',
  };

  /// 解決対象の文字列か（空・「なし」等は対象外）
  static bool isResolvable(String? address) {
    if (address == null) return false;
    final t = address.trim();
    return !_ignoredValues.contains(t);
  }

  /// 1 件の送迎場所を解決する（UI の「候補を取得」でも使用）
  ///
  /// 戻り値の outcome に応じて呼び出し側が UI を分岐する。
  /// [persist] = true のとき autoAdopted / failed を Hive に保存する。
  Future<(ResolveOutcome, GeocodeCandidatesResult?)> resolveOne(
    Customer customer,
    int index, {
    required CandidateFetcher fetch,
    bool persist = true,
    bool force = false,
  }) async {
    if (index < 0 || index >= customer.transportLocations.length) {
      return (ResolveOutcome.skippedEmpty, null);
    }
    final address = customer.transportLocations[index];
    if (!isResolvable(address)) {
      return (ResolveOutcome.skippedEmpty, null);
    }
    if (!force && customer.isTransportResolved(index)) {
      debugPrint('[Resolver] ${customer.name}[$index] already resolved → skip API');
      return (ResolveOutcome.alreadyResolved, null);
    }

    GeocodeCandidatesResult result;
    try {
      result = await fetch(address.trim());
    } catch (e) {
      debugPrint('[Resolver] ${customer.name}[$index] "$address" failed: $e');
      customer.setTransportCoord(index, null, null, Customer.locFailed);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      return (ResolveOutcome.failed, null);
    }

    if (result.isEmpty) {
      debugPrint('[Resolver] ${customer.name}[$index] "$address" → 0件 → failed');
      customer.setTransportCoord(index, null, null, Customer.locFailed);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      return (ResolveOutcome.failed, result);
    }

    if (result.isSingle) {
      final c = result.candidates.first;
      customer.setTransportCoord(index, c.lat, c.lng, Customer.locResolved);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      debugPrint('[Resolver] ${customer.name}[$index] "$address" → auto "${c.formattedAddress}"'
          '${c.isOutsideObihiroBounds ? ' ⚠帯広市外' : ''}');
      return (ResolveOutcome.autoAdopted, result);
    }

    debugPrint('[Resolver] ${customer.name}[$index] "$address" → ${result.candidates.length}件 → 選択待ち');
    return (ResolveOutcome.pendingSelection, result);
  }

  /// ユーザーが候補を採用（status=manual）
  Future<void> adoptCandidate(
    Customer customer,
    int index,
    GeocodeCandidate candidate, {
    bool persist = true,
  }) async {
    customer.setTransportCoord(index, candidate.lat, candidate.lng, Customer.locManual);
    if (persist) await CustomerService.instance.updateCustomer(customer);
    debugPrint('[Resolver] ${customer.name}[$index] manual adopt "${candidate.formattedAddress}" '
        '(${candidate.lat.toStringAsFixed(6)}, ${candidate.lng.toStringAsFixed(6)})');
  }

  /// 地図で微調整した座標を採用（status=manual）
  Future<void> adoptManualCoord(
    Customer customer,
    int index,
    double lat,
    double lng, {
    bool persist = true,
  }) async {
    customer.setTransportCoord(index, lat, lng, Customer.locManual);
    if (persist) await CustomerService.instance.updateCustomer(customer);
    debugPrint('[Resolver] ${customer.name}[$index] manual coord '
        '(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)})');
  }

  /// 座標解除（status=unresolved）
  Future<void> clearCoord(Customer customer, int index, {bool persist = true}) async {
    customer.setTransportCoord(index, null, null, Customer.locUnresolved);
    if (persist) await CustomerService.instance.updateCustomer(customer);
  }

  /// 未解決・失敗の全送迎場所を順次解決する（1 件ずつ、[interval] 間隔）
  ///
  /// [onProgress] で進捗通知。複数候補は summary.pendingQueue に積まれる。
  Future<ResolveSummary> resolveAll(
    List<Customer> customers, {
    required CandidateFetcher fetch,
    Duration interval = const Duration(milliseconds: 200),
    bool includeFailed = true,
    void Function(ResolveProgress p)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final summary = ResolveSummary();
    // 対象列挙
    final targets = <(Customer, int)>[];
    for (final c in customers) {
      for (int i = 0; i < c.transportLocations.length; i++) {
        if (!isResolvable(c.transportLocations[i])) continue;
        if (c.isTransportResolved(i)) {
          summary.alreadyResolved++;
          continue;
        }
        if (!includeFailed && c.transportStatus(i) == Customer.locFailed) continue;
        targets.add((c, i));
      }
    }
    debugPrint('[Resolver] resolveAll: targets=${targets.length}, '
        'alreadyResolved=${summary.alreadyResolved}');

    for (int k = 0; k < targets.length; k++) {
      if (isCancelled?.call() ?? false) {
        debugPrint('[Resolver] resolveAll cancelled at $k/${targets.length}');
        break;
      }
      final (c, i) = targets[k];
      onProgress?.call(ResolveProgress(
          done: k, total: targets.length, current: c, currentIndex: i));

      final (outcome, result) = await resolveOne(c, i, fetch: fetch);
      switch (outcome) {
        case ResolveOutcome.autoAdopted:
          summary.autoAdopted++;
        case ResolveOutcome.pendingSelection:
          summary.pending++;
          summary.pendingQueue.add(PendingSelection(
            customer: c,
            index: i,
            address: c.transportLocations[i],
            candidates: result?.candidates ?? const [],
          ));
        case ResolveOutcome.failed:
          summary.failed++;
          summary.failures.add((c, i, result == null ? 'API エラー' : '該当なし'));
        case ResolveOutcome.skippedEmpty:
          summary.skipped++;
        case ResolveOutcome.alreadyResolved:
          summary.alreadyResolved++;
      }
      if (k < targets.length - 1 && interval > Duration.zero) {
        await Future.delayed(interval);
      }
    }
    onProgress?.call(ResolveProgress(done: targets.length, total: targets.length));
    debugPrint('[Resolver] resolveAll done: auto=${summary.autoAdopted}, '
        'pending=${summary.pending}, failed=${summary.failed}, '
        'alreadyResolved=${summary.alreadyResolved}, apiCalls=${summary.apiCalls}');
    return summary;
  }

  /// 全顧客の解決状況サマリー（画面ヘッダー用）
  static ({int total, int resolved, int manual, int failed, int unresolved}) countStatus(
      List<Customer> customers) {
    int total = 0, resolved = 0, manual = 0, failed = 0, unresolved = 0;
    for (final c in customers) {
      for (int i = 0; i < c.transportLocations.length; i++) {
        if (!isResolvable(c.transportLocations[i])) continue;
        total++;
        switch (c.transportStatus(i)) {
          case Customer.locResolved:
            if (c.transportCoord(i) != null) {
              resolved++;
            } else {
              unresolved++;
            }
          case Customer.locManual:
            if (c.transportCoord(i) != null) {
              manual++;
            } else {
              unresolved++;
            }
          case Customer.locFailed:
            failed++;
          default:
            unresolved++;
        }
      }
    }
    return (total: total, resolved: resolved, manual: manual, failed: failed, unresolved: unresolved);
  }
}
