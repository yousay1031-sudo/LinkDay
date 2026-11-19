// 検証用の送迎計画（架空）。今日: お迎え 3 台 / お送り 2 台。
//
// 以前 lib/verify/verify_seed.dart が Hive に入れていたものと同じ規則
// （送迎計画は段階6で Firestore へ移した）。乗る人は週間利用計画の今日のスロット
// （dummy_schedule.mjs の buildDemoWeeks。キャンセルは除く）。
import { buildCustomer, CUSTOMER_COUNT } from './dummy_customers.mjs';
import { buildDemoWeeks, ymd } from './dummy_schedule.mjs';

const hhmm = (h, m) => `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
const NAMES = ['車両A', '車両B', '車両C'];

/** → [{ id: '{date}_{pickup|dropoff}_{v}', data }]（lib/models/transport_plan.dart の toFirestoreData と同じ形） */
export function buildDemoTransport(today) {
  const byId = new Map();
  for (let n = 1; n <= CUSTOMER_COUNT; n++) {
    const c = buildCustomer(n, today);
    byId.set(c.id, c);
  }
  const slot = buildDemoWeeks(today)[1].slots.find((s) => ymd(s.date) === ymd(today));
  const riders = slot.entries.filter((e) => e.status !== 'cancelled').map((e) => byId.get(e.customerId));
  const date = ymd(today);
  const out = [];
  for (const type of ['pickup', 'dropoff']) {
    const vehicles = type === 'pickup' ? 3 : 2;
    for (let v = 0; v < vehicles; v++) {
      const mine = [];
      for (let i = v; i < riders.length; i += vehicles) mine.push(riders[i]);
      const take = mine.slice(0, v === 2 ? 4 : 6);
      out.push({
        id: `${date}_${type}_${v}`,
        data: {
          routeId: `dummy-route-${type}-${v}`,
          date,
          transportType: type,
          vehicleIndex: v,
          vehicleName: NAMES[v],
          capacity: v === 2 ? 4 : 6,
          stops: take.map((c, i) => ({
            customerId: c.id,
            customerName: c.data.name,
            address: c.data.transportLocations[0].address,
            lat: c.data.transportLocations[0].lat,
            lng: c.data.transportLocations[0].lng,
            orderIndex: i,
            scheduledTime: hhmm(9 + Math.floor(i / 2), (i % 2) * 30 + 5 + v),
            distanceFromPrevMeters: 800 + i * 350,
            durationFromPrevSeconds: 240 + i * 60,
            note: null,
          })),
          googleMapsUrl: null,
          totalDistanceMeters: 4200 + v * 900,
          totalDurationSeconds: 1500 + v * 300,
          optimizedAt: null,
          note: null,
        },
      });
    }
  }
  return out;
}
