import 'package:flutter/foundation.dart';

import '../models/customer.dart';
import '../models/geocode_candidate.dart';
import 'customer_service.dart';

/// 候補取得関数（本番は MapsJsService.geocodeCandidates、テストでは差し替え）
typedef CandidateFetcher = Future<GeocodeCandidatesResult> Function(String address);

/// 一括解決の 1 件分の結果種別
enum ResolveOutcome {
  autoAdopted, // 自動採用可（帯広市内・地点粒度・完全一致）→ resolved
  pendingSelection, // 複数候補 or 自動採用不可 → ユーザー選択待ち
  failed, // 0 件 or API エラー → failed
  skippedEmpty, // 空文字・「なし」等 → 対象外
  alreadyResolved, // 既に resolved/manual → API 未呼び出し
}

/// 自動採用を却下した理由（Day 8 修正）
enum AutoAdoptBlockReason {
  outsideBounds, // 帯広市外（bounds 外）
  countryLevel, // 「日本」等、国レベルの座標
  coarseGranularity, // locality / 県レベル等、地点粒度を持たない
  partialMatch, // 部分一致
}

extension AutoAdoptBlockReasonLabel on AutoAdoptBlockReason {
  /// ログ・UI 表示用の日本語理由
  String get label => switch (this) {
        AutoAdoptBlockReason.outsideBounds => '帯広市外のため',
        AutoAdoptBlockReason.countryLevel => '国レベル座標（「日本」）のため',
        AutoAdoptBlockReason.coarseGranularity => '粒度不足',
        AutoAdoptBlockReason.partialMatch => '部分一致のため',
      };

  /// UI チップ用の短いラベル
  String get shortLabel => switch (this) {
        AutoAdoptBlockReason.outsideBounds => '帯広市外',
        AutoAdoptBlockReason.countryLevel => '「日本」レベル',
        AutoAdoptBlockReason.coarseGranularity => '粒度不足',
        AutoAdoptBlockReason.partialMatch => '部分一致',
      };
}

/// 候補 1 件の自動採用可否判定の結果
class AutoAdoptJudgement {
  final bool allowed;
  final List<AutoAdoptBlockReason> reasons;
  final GeocodeCandidate candidate;

  const AutoAdoptJudgement({
    required this.allowed,
    required this.reasons,
    required this.candidate,
  });

  /// ログ出力用の理由文字列（例: '帯広市外のため' / '粒度不足（locality）'）
  String get reasonText {
    if (reasons.isEmpty) return '';
    return reasons.map((r) {
      if (r == AutoAdoptBlockReason.coarseGranularity) {
        return '${r.label}（${candidate.coarseType}）';
      }
      return r.label;
    }).join(' / ');
  }

  /// UI チップ用の短い理由群
  List<String> get shortReasons => reasons.map((r) => r.shortLabel).toList();
}

/// 選択待ちキューの 1 件
class PendingSelection {
  final Customer customer;
  final int index; // 送迎場所 index 0..2
  final String address; // 表示用の元文字列
  final String query; // 実際に投げたクエリ（補完後）
  final List<GeocodeCandidate> candidates;

  /// 自動採用がブロックされた理由（複数候補による選択待ちなら空）
  final List<AutoAdoptBlockReason> blockReasons;

  const PendingSelection({
    required this.customer,
    required this.index,
    required this.address,
    required this.candidates,
    String? query,
    this.blockReasons = const [],
  }) : query = query ?? address;

  /// 1 件ヒットだが自動採用不可でキューに回されたか
  bool get isBlockedAutoAdopt => blockReasons.isNotEmpty;

  String get blockReasonText => blockReasons
      .map((r) => r == AutoAdoptBlockReason.coarseGranularity
          ? '${r.label}（${candidates.isNotEmpty ? candidates.first.coarseType : '不明'}）'
          : r.label)
      .join(' / ');
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
  int blocked = 0; // 1 件ヒットだが自動採用不可でキューに回した件数
  int failed = 0;
  int skipped = 0;
  int alreadyResolved = 0;
  final List<PendingSelection> pendingQueue = [];
  final List<(Customer, int, String)> failures = []; // (customer, index, reason)

  int get apiCalls => autoAdopted + pending + failed;
}

// ════════════════════════════════════════════════════════════════
// Day 8 追加改修: 地図から直接ピン指定（最終手段）
// ════════════════════════════════════════════════════════════════

/// 地図ピン指定の初期位置の決定根拠
enum PinInitialSource {
  ownCoord, // 当該送迎場所の採用済み座標
  siblingCoord, // 同一児童の他の送迎場所の採用済み座標
  facility, // 事業所座標（Settings）
  obihiroCenter, // 帯広市中心フォールバック
}

extension PinInitialSourceLabel on PinInitialSource {
  /// UI・ログ表示用の日本語ラベル
  String get label => switch (this) {
        PinInitialSource.ownCoord => 'この場所の採用済み座標',
        PinInitialSource.siblingCoord => '同じ児童の他の送迎場所',
        PinInitialSource.facility => '事業所の位置',
        PinInitialSource.obihiroCenter => '帯広市中心',
      };
}

/// 「地図から直接指定」の初期カメラ位置
class MapPinInitial {
  final double lat;
  final double lng;
  final double zoom;
  final PinInitialSource source;

  /// source == siblingCoord のとき、参照した送迎場所の index
  final int? sourceIndex;

  const MapPinInitial({
    required this.lat,
    required this.lng,
    required this.zoom,
    required this.source,
    this.sourceIndex,
  });

  /// UI 表示用の根拠説明（例: 「同じ児童の他の送迎場所（送迎場所1）を基準に表示」）
  String get sourceDescription => switch (source) {
        PinInitialSource.siblingCoord =>
          '${source.label}（送迎場所${(sourceIndex ?? 0) + 1}）を基準に表示',
        PinInitialSource.ownCoord => '${source.label}を表示',
        _ => '${source.label}を基準に表示',
      };

  @override
  String toString() => 'MapPinInitial(${lat.toStringAsFixed(6)}, '
      '${lng.toStringAsFixed(6)}, zoom=$zoom, ${source.name})';
}

/// 誤採用リセットの対象 1 件
class SuspectAdoption {
  final Customer customer;
  final int index;
  final String address;
  final List<AutoAdoptBlockReason> reasons;
  final double lat;
  final double lng;
  final String? formatted;

  const SuspectAdoption({
    required this.customer,
    required this.index,
    required this.address,
    required this.reasons,
    required this.lat,
    required this.lng,
    this.formatted,
  });

  String get reasonText => reasons.map((r) => r.shortLabel).join(' / ');
}

/// 送迎場所ジオコーディング解決サービス（Day 8 / 誤ジオコード自動採用の防止）
///
/// 【自動採用の厳格化】
/// 候補が 1 件でも以下に該当する場合は自動採用せず pending_selection キューへ回す:
///   - bounds 外（isOutsideObihiroBounds）
///   - formattedAddress が「日本」だけ、または locality / 県レベルの粒度
///     （types に premise/park/transit_station/school/establishment/
///       street_address/route のいずれも含まない）
///   - partialMatch == true
///
/// 【短名クエリの自動補完】
/// 入力文字列が「北海道」「帯広市」を含まない場合、
/// geocode クエリを「北海道帯広市 {入力}」に補完して実行する（表示文字列は不変）。
class TransportLocationResolver {
  TransportLocationResolver._();
  static final TransportLocationResolver instance = TransportLocationResolver._();

  /// 解決対象外とみなす文字列
  static const Set<String> _ignoredValues = {
    '', 'なし', '無し', '-', '－', '—', 'ー', '未定', 'TBD', 'N/A', 'n/a',
  };

  /// クエリ補完のプレフィックス
  static const String queryPrefix = '北海道帯広市';

  /// 補完をスキップする判定キーワード（既に地域が明示されている）
  static const List<String> _regionKeywords = ['北海道', '帯広市'];

  /// 解決対象の文字列か（空・「なし」等は対象外）
  static bool isResolvable(String? address) {
    if (address == null) return false;
    final t = address.trim();
    return !_ignoredValues.contains(t);
  }

  // ── 修正2: 短名クエリの自動補完 ───────────────────────────────

  /// 「北海道」「帯広市」を含まない入力に「北海道帯広市 」を前置する
  ///
  /// 表示上の元文字列（transportLocations）は変更せず、クエリのみ補完する。
  /// 例: "南公園" → "北海道帯広市 南公園"
  ///     "北海道帯広市西4条南10丁目" → そのまま
  static String buildGeocodeQuery(String address) {
    final t = address.trim();
    if (t.isEmpty) return t;
    if (_regionKeywords.any((k) => t.contains(k))) return t;
    return '$queryPrefix $t';
  }

  /// クエリ補完が適用されるか
  static bool needsQueryAugment(String address) =>
      buildGeocodeQuery(address) != address.trim();

  // ── 修正1: 自動採用の厳格化 ──────────────────────────────────

  /// 候補 1 件を自動採用して良いか判定する
  static AutoAdoptJudgement judgeAutoAdopt(GeocodeCandidate c) {
    final reasons = <AutoAdoptBlockReason>[];
    if (c.isOutsideObihiroBounds) {
      reasons.add(AutoAdoptBlockReason.outsideBounds);
    }
    if (c.isCountryLevel) {
      reasons.add(AutoAdoptBlockReason.countryLevel);
    } else if (!c.hasPointGranularity) {
      // 「日本」レベルは countryLevel として既に報告済みなので二重計上しない
      reasons.add(AutoAdoptBlockReason.coarseGranularity);
    }
    if (c.partialMatch) {
      reasons.add(AutoAdoptBlockReason.partialMatch);
    }
    return AutoAdoptJudgement(
        allowed: reasons.isEmpty, reasons: reasons, candidate: c);
  }

  /// この候補を「保存して良い座標」として許容するか（手動採用の最終ガード）
  ///
  /// 受け入れ基準5: 「日本」レベルの座標はどの経路でも保存されない。
  static bool isStorableCandidate(GeocodeCandidate c) => !c.isCountryLevel;

  /// 既に保存済みの座標が「誤採用（帯広市外・粒度不足）」かを判定する
  ///
  /// 採用根拠メタ（formatted / types）がある場合はそれで判定し、
  /// 旧データ（メタ無し）は座標が bounds 外かどうかだけで判定する。
  static List<AutoAdoptBlockReason> judgeStoredCoord(Customer c, int i) {
    final coord = c.transportCoord(i);
    if (coord == null) return const [];
    final reasons = <AutoAdoptBlockReason>[];
    final pseudo = GeocodeCandidate(
      formattedAddress: c.transportFormatted(i) ?? '',
      lat: coord.lat,
      lng: coord.lng,
      types: c.transportTypes(i),
    );
    if (pseudo.isOutsideObihiroBounds) {
      reasons.add(AutoAdoptBlockReason.outsideBounds);
    }
    if (c.hasTransportMeta(i)) {
      if (pseudo.isCountryLevel) {
        reasons.add(AutoAdoptBlockReason.countryLevel);
      } else if (!pseudo.hasPointGranularity) {
        reasons.add(AutoAdoptBlockReason.coarseGranularity);
      }
    }
    return reasons;
  }

  /// 1 件の送迎場所を解決する（UI の「候補を取得」でも使用）
  ///
  /// [persist] = true のとき autoAdopted / failed を Hive に保存する。
  Future<(ResolveOutcome, GeocodeCandidatesResult?, AutoAdoptJudgement?)> resolveOneDetailed(
    Customer customer,
    int index, {
    required CandidateFetcher fetch,
    bool persist = true,
    bool force = false,
  }) async {
    if (index < 0 || index >= customer.transportLocations.length) {
      return (ResolveOutcome.skippedEmpty, null, null);
    }
    final address = customer.transportLocations[index];
    if (!isResolvable(address)) {
      return (ResolveOutcome.skippedEmpty, null, null);
    }
    if (!force && customer.isTransportResolved(index)) {
      debugPrint('[Resolver] ${customer.name}[$index] already resolved → skip API');
      return (ResolveOutcome.alreadyResolved, null, null);
    }

    // 修正2: 短名クエリの自動補完
    final query = buildGeocodeQuery(address);
    if (query != address.trim()) {
      debugPrint('[Resolver] query augment: "$address" → "$query"');
    }

    GeocodeCandidatesResult result;
    try {
      result = await fetch(query);
    } catch (e) {
      debugPrint('[Resolver] ${customer.name}[$index] "$query" failed: $e');
      customer.setTransportCoord(index, null, null, Customer.locFailed);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      return (ResolveOutcome.failed, null, null);
    }

    if (result.isEmpty) {
      debugPrint('[Resolver] ${customer.name}[$index] "$query" → 0件 → failed');
      customer.setTransportCoord(index, null, null, Customer.locFailed);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      return (ResolveOutcome.failed, result, null);
    }

    if (result.isSingle) {
      final c = result.candidates.first;
      final j = judgeAutoAdopt(c);
      if (!j.allowed) {
        // 修正1: 自動採用せず選択待ちキューへ（status は変更しない）
        debugPrint('[Resolver] auto-adopt blocked: "$address" → ${j.reasonText}');
        return (ResolveOutcome.pendingSelection, result, j);
      }
      customer.setTransportCoord(index, c.lat, c.lng, Customer.locResolved,
          formatted: c.formattedAddress, types: c.types);
      if (persist) await CustomerService.instance.updateCustomer(customer);
      debugPrint('[Resolver] ${customer.name}[$index] "$address" → auto adopt '
          '"${c.formattedAddress}" [${c.primaryType}]');
      return (ResolveOutcome.autoAdopted, result, j);
    }

    debugPrint('[Resolver] ${customer.name}[$index] "$query" → '
        '${result.candidates.length}件 → 選択待ち');
    return (ResolveOutcome.pendingSelection, result, null);
  }

  /// 既存 API 互換ラッパー（2 値タプル）
  Future<(ResolveOutcome, GeocodeCandidatesResult?)> resolveOne(
    Customer customer,
    int index, {
    required CandidateFetcher fetch,
    bool persist = true,
    bool force = false,
  }) async {
    final (o, r, _) = await resolveOneDetailed(customer, index,
        fetch: fetch, persist: persist, force: force);
    return (o, r);
  }

  /// ユーザーが候補を採用（status=manual）
  ///
  /// 「日本」レベル（国レベル重心）の候補は採用を拒否する（受け入れ基準5）。
  /// 戻り値: 採用したか
  Future<bool> adoptCandidate(
    Customer customer,
    int index,
    GeocodeCandidate candidate, {
    bool persist = true,
  }) async {
    if (!isStorableCandidate(candidate)) {
      debugPrint('[Resolver] adopt rejected: "${candidate.formattedAddress}" は'
          '国レベル座標のため保存しません');
      return false;
    }
    customer.setTransportCoord(
        index, candidate.lat, candidate.lng, Customer.locManual,
        formatted: candidate.formattedAddress, types: candidate.types);
    if (persist) await CustomerService.instance.updateCustomer(customer);
    debugPrint('[Resolver] ${customer.name}[$index] manual adopt '
        '"${candidate.formattedAddress}" '
        '(${candidate.lat.toStringAsFixed(6)}, ${candidate.lng.toStringAsFixed(6)})'
        '${candidate.isOutsideObihiroBounds ? ' ⚠帯広市外' : ''}');
    return true;
  }

  /// 地図で微調整した座標を採用（status=manual）
  ///
  /// [formatted] に逆ジオコーディングで取得した住所を渡せる。
  /// 取得できなかった場合は「手動指定地点」を既定表示として保存する
  /// （座標が本体。住所表示は補助情報）。
  Future<void> adoptManualCoord(
    Customer customer,
    int index,
    double lat,
    double lng, {
    bool persist = true,
    String? formatted,
  }) async {
    final label = sanitizeManualLabel(formatted);
    customer.setTransportCoord(index, lat, lng, Customer.locManual,
        formatted: label, types: manualPinTypes);
    if (persist) await CustomerService.instance.updateCustomer(customer);
    debugPrint('[Resolver] ${customer.name}[$index] manual coord '
        '(${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}) "$label"'
        '${GeocodeCandidate(formattedAddress: label, lat: lat, lng: lng).isOutsideObihiroBounds ? ' ⚠帯広市外（手動配置は許可）' : ''}');
  }

  // ── Day 8 追加改修: 地図から直接ピン指定（最終手段） ───────────

  /// 逆ジオコーディング失敗時の住所表示ラベル
  static const String manualPinLabel = '手動指定地点';

  /// 手動ピン指定の types
  ///
  /// `premise`（地点粒度）を付与することで、
  /// findSuspectAdoptions の粒度不足判定に掛からないようにする。
  /// さらに status=manual なのでリセット対象からも除外される（二重の保護）。
  static const List<String> manualPinTypes = ['premise'];

  /// 手動ピンの住所ラベルを安全な値に整える
  ///
  /// 逆ジオコーディングが「日本」のような国レベルの住所を返すことがある
  /// （海上・原野など周辺に住所が無い地点）。この文字列をそのまま
  /// formatted に保存すると CustomerService.sanitizeCoords が
  /// 「国レベル座標」と誤認し、ユーザーが意図して置いたピンを破棄してしまう。
  /// そのため国レベル表記は保存せず [manualPinLabel] に置き換える。
  static String sanitizeManualLabel(String? formatted) {
    final t = (formatted ?? '').trim();
    if (t.isEmpty) return manualPinLabel;
    if (t == '日本' || t == '日本国' || t == 'Japan') {
      debugPrint('[Resolver] 逆ジオコード結果が国レベル（"$t"）のため '
          '"$manualPinLabel" として保存します（座標は維持）');
      return manualPinLabel;
    }
    return t;
  }

  /// 帯広市中心（初期位置の最終フォールバック）
  static const double obihiroCenterLat = 42.9077437;
  static const double obihiroCenterLng = 143.1996431;

  /// 「地図から直接指定」の初期位置を決定する
  ///
  /// 優先順:
  ///   1. 当該送迎場所の採用済み座標（ズーム 16）
  ///   2. 同一児童の他の送迎場所の採用済み座標（場所1優先、ズーム 15）
  ///   3. 事業所座標（Settings の facilityLat/Lng、ズーム 15）
  ///   4. 帯広市中心フォールバック（ズーム 13）
  ///
  /// 「日本全図から始まらない」ことを保証するため、必ず帯広周辺を返す。
  static MapPinInitial resolveInitialPinPosition(
    Customer customer,
    int index, {
    double? facilityLat,
    double? facilityLng,
  }) {
    // 1. 当該場所の採用済み座標
    final own = customer.transportCoord(index);
    if (own != null && customer.isTransportResolved(index)) {
      return MapPinInitial(
          lat: own.lat, lng: own.lng, zoom: 16, source: PinInitialSource.ownCoord);
    }

    // 2. 同一児童の他場所の採用済み座標（index 昇順 = 場所1優先）
    for (int i = 0; i < customer.transportLocations.length; i++) {
      if (i == index) continue;
      final other = customer.transportCoord(i);
      if (other != null && customer.isTransportResolved(i)) {
        return MapPinInitial(
            lat: other.lat,
            lng: other.lng,
            zoom: 15,
            source: PinInitialSource.siblingCoord,
            sourceIndex: i);
      }
    }

    // 3. 事業所座標
    if (facilityLat != null && facilityLng != null) {
      return MapPinInitial(
          lat: facilityLat,
          lng: facilityLng,
          zoom: 15,
          source: PinInitialSource.facility);
    }

    // 4. 帯広市中心フォールバック
    return const MapPinInitial(
        lat: obihiroCenterLat,
        lng: obihiroCenterLng,
        zoom: 13,
        source: PinInitialSource.obihiroCenter);
  }

  /// 座標解除（status=unresolved）
  Future<void> clearCoord(Customer customer, int index, {bool persist = true}) async {
    customer.setTransportCoord(index, null, null, Customer.locUnresolved);
    if (persist) await CustomerService.instance.updateCustomer(customer);
  }

  // ── 修正3: 既存誤採用データの一括リセット ─────────────────────

  /// 帯広市外・粒度不足の採用済み座標を列挙する（件数の事前表示用）
  static List<SuspectAdoption> findSuspectAdoptions(List<Customer> customers) {
    final out = <SuspectAdoption>[];
    for (final c in customers) {
      for (int i = 0; i < c.transportLocations.length; i++) {
        if (!isResolvable(c.transportLocations[i])) continue;
        final st = c.transportStatus(i);
        // 自動採用（resolved）のみを対象とする。
        // ユーザーが明示的に選んだ manual は尊重する（受け入れ基準6）。
        if (st != Customer.locResolved) continue;
        final coord = c.transportCoord(i);
        if (coord == null) continue;
        final reasons = judgeStoredCoord(c, i);
        if (reasons.isEmpty) continue;
        out.add(SuspectAdoption(
          customer: c,
          index: i,
          address: c.transportLocations[i],
          reasons: reasons,
          lat: coord.lat,
          lng: coord.lng,
          formatted: c.transportFormatted(i),
        ));
      }
    }
    return out;
  }

  /// 誤採用を一括で unresolved に戻す（再解決キューへ）
  ///
  /// 戻り値: 実際に解除した件数
  Future<int> resetSuspectAdoptions(
    List<Customer> customers, {
    bool persist = true,
  }) async {
    final targets = findSuspectAdoptions(customers);
    debugPrint('[Resolver] resetSuspectAdoptions: ${targets.length}件を解除します');
    for (final t in targets) {
      debugPrint('[Resolver] reset: ${t.customer.name}[${t.index}] "${t.address}" '
          '→ ${t.reasonText}（${t.formatted ?? '根拠不明'} '
          '${t.lat.toStringAsFixed(5)},${t.lng.toStringAsFixed(5)}）');
      t.customer.setTransportCoord(t.index, null, null, Customer.locUnresolved);
    }
    if (persist) {
      // 顧客単位で 1 回だけ保存する
      final seen = <String>{};
      for (final t in targets) {
        if (seen.add(t.customer.id)) {
          await CustomerService.instance.updateCustomer(t.customer);
        }
      }
    }
    debugPrint('[Resolver] resetSuspectAdoptions done: ${targets.length}件 → unresolved');
    return targets.length;
  }

  /// 未解決・失敗の全送迎場所を順次解決する（1 件ずつ、[interval] 間隔）
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

      final (outcome, result, judgement) =
          await resolveOneDetailed(c, i, fetch: fetch);
      switch (outcome) {
        case ResolveOutcome.autoAdopted:
          summary.autoAdopted++;
        case ResolveOutcome.pendingSelection:
          summary.pending++;
          final blocked = judgement != null && !judgement.allowed;
          if (blocked) summary.blocked++;
          summary.pendingQueue.add(PendingSelection(
            customer: c,
            index: i,
            address: c.transportLocations[i],
            query: buildGeocodeQuery(c.transportLocations[i]),
            candidates: result?.sortedByPreference ?? const [],
            blockReasons: blocked ? judgement.reasons : const [],
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
        'pending=${summary.pending}（うち自動採用不可 ${summary.blocked}）, '
        'failed=${summary.failed}, alreadyResolved=${summary.alreadyResolved}, '
        'apiCalls=${summary.apiCalls}');
    return summary;
  }

  /// 全顧客の解決状況サマリー（画面ヘッダー用）
  static ({int total, int resolved, int manual, int failed, int unresolved, int suspect})
      countStatus(List<Customer> customers) {
    int total = 0, resolved = 0, manual = 0, failed = 0, unresolved = 0, suspect = 0;
    for (final c in customers) {
      for (int i = 0; i < c.transportLocations.length; i++) {
        if (!isResolvable(c.transportLocations[i])) continue;
        total++;
        switch (c.transportStatus(i)) {
          case Customer.locResolved:
            if (c.transportCoord(i) != null) {
              resolved++;
              if (judgeStoredCoord(c, i).isNotEmpty) suspect++;
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
    return (
      total: total,
      resolved: resolved,
      manual: manual,
      failed: failed,
      unresolved: unresolved,
      suspect: suspect,
    );
  }
}
