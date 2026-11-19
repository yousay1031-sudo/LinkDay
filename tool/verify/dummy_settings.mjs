// 検証用の事業所の設定（架空）。facilities/{facilityId}/settings/app に置く。
//
// 以前 lib/verify/verify_seed.dart が Hive に入れていたものと同じ値（設定は段階7で
// Firestore へ移した）。Maps の API キーは設定に置かない（端末の SharedPreferences）。
// 値の形は lib/models/app_settings.dart の toFirestoreData と同じ。
export function buildDemoSettings() {
  return {
    facilityName: '検証用デイサービス（ダミー）',
    facilityAddress: '北海道帯広市（検証用ダミー住所）',
    facilityLat: 42.9236,
    facilityLng: 143.1946,
    vehicleCount: 3,
    vehicleNames: ['車両A', '車両B', '車両C'],
    vehicleCapacities: [6, 6, 4],
    maxStudentsPerDay: 20,
    defaultPickupStart: '08:30',
    defaultDropoffEnd: '16:30',
    vacancyReplyDeadline: '13:00',
    vacancyMessageTemplate:
      '【{facility}】\n' +
      '本日（{date}）、急なキャンセルにより空き枠が出ました。\n' +
      'ご利用を希望される場合は {deadline} までにお電話でご連絡ください。\n' +
      '※先着順となりますのでご了承ください。',
    slotTtlHours: 6,
    adminLineUserId: null,
    staffPinEnabled: false,
  };
}
