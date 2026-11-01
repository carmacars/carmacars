// The tracker simulator (migration 0400): fake cars driving the GTA's highways, the same way at the same moment wherever it
// runs. It feeds the dev and test ingest (web/scripts/tracker-sim.mjs posts signed batches to /api/tracker/ingest) and
// Admin's demo mode (Fleet tracking and the Live map draw it with no database write at all). No imports: unit tested in
// Node (sim.test.ts) and run in the browser.
//
// The odometer adds the distance driven, wrapping every 5,000 km (a trip across the wrap falls back to the GPS distance).
// Each car drives one highway back and forth at its own speed: 20 minutes on the road, then 4 minutes parked with the
// ignition off (so trips start and end), one car always parked downtown. One car drives well over the speeding level, one
// has a low tracker battery and one is unplugged, so every alert shows in demo mode.

/** The highways of the Live map's basemap (public/live-map/highways.geojson), longitude and latitude. */
export const ROUTES: Array<[string, Array<[number, number]>]> = [
  ["401", [[-79.985,43.497],[-79.946,43.508],[-79.918,43.519],[-79.885,43.532],[-79.855,43.547],[-79.83,43.563],[-79.808,43.578],[-79.78,43.588],[-79.752,43.598],[-79.728,43.611],[-79.705,43.624],[-79.688,43.633],[-79.672,43.641],[-79.648,43.651],[-79.628,43.658],[-79.606,43.665],[-79.592,43.672],[-79.578,43.686],[-79.562,43.701],[-79.54,43.712],[-79.524,43.719],[-79.506,43.722],[-79.486,43.725],[-79.462,43.729],[-79.447,43.731],[-79.422,43.739],[-79.406,43.745],[-79.386,43.752],[-79.366,43.759],[-79.345,43.765],[-79.318,43.772],[-79.3,43.776],[-79.279,43.781],[-79.247,43.789],[-79.224,43.794],[-79.199,43.801],[-79.167,43.803],[-79.142,43.806],[-79.115,43.816],[-79.087,43.828],[-79.06,43.839],[-79.035,43.851],[-79,43.86],[-78.96,43.864],[-78.94,43.866],[-78.912,43.869],[-78.885,43.876],[-78.862,43.882],[-78.835,43.888],[-78.795,43.894],[-78.745,43.902],[-78.7,43.906]]],
  ["QEW", [[-79.556,43.616],[-79.582,43.603],[-79.603,43.59],[-79.62,43.578],[-79.646,43.559],[-79.668,43.54],[-79.682,43.525],[-79.69,43.513],[-79.696,43.495],[-79.704,43.476],[-79.718,43.463],[-79.738,43.447],[-79.752,43.433],[-79.775,43.411],[-79.791,43.396],[-79.806,43.38],[-79.816,43.366],[-79.826,43.352],[-79.835,43.342],[-79.822,43.327],[-79.8,43.306]]],
  ["427", [[-79.556,43.616],[-79.566,43.628],[-79.578,43.644],[-79.587,43.658],[-79.592,43.672],[-79.598,43.692],[-79.602,43.715],[-79.606,43.74],[-79.611,43.762],[-79.621,43.788],[-79.632,43.815],[-79.638,43.84]]],
  ["404", [[-79.343,43.765],[-79.342,43.778],[-79.349,43.793],[-79.356,43.812],[-79.362,43.835],[-79.367,43.852],[-79.372,43.871],[-79.378,43.9],[-79.383,43.93],[-79.387,43.96],[-79.392,43.985],[-79.401,44.012],[-79.412,44.045],[-79.421,44.075],[-79.428,44.105],[-79.436,44.13]]],
  ["DVP", [[-79.353,43.653],[-79.357,43.664],[-79.358,43.676],[-79.351,43.687],[-79.338,43.697],[-79.333,43.708],[-79.331,43.721],[-79.333,43.735],[-79.338,43.748],[-79.343,43.765]]],
  ["Gardiner", [[-79.556,43.616],[-79.537,43.619],[-79.516,43.621],[-79.497,43.624],[-79.484,43.628],[-79.472,43.632],[-79.459,43.635],[-79.443,43.635],[-79.428,43.634],[-79.412,43.636],[-79.398,43.638],[-79.383,43.641],[-79.37,43.645],[-79.36,43.649],[-79.353,43.653]]],
  ["410", [[-79.672,43.641],[-79.682,43.66],[-79.696,43.68],[-79.71,43.699],[-79.727,43.718],[-79.746,43.738],[-79.77,43.756],[-79.802,43.77],[-79.845,43.781]]],
  ["400", [[-79.524,43.719],[-79.528,43.745],[-79.532,43.772],[-79.535,43.79],[-79.539,43.83],[-79.546,43.873],[-79.56,43.918],[-79.576,43.965],[-79.588,44.02],[-79.598,44.075],[-79.608,44.13]]],
  ["403", [[-79.672,43.641],[-79.66,43.62],[-79.649,43.603],[-79.668,43.594],[-79.698,43.583],[-79.72,43.567],[-79.728,43.546],[-79.712,43.526],[-79.69,43.513]]],
  ["407", [[-79.835,43.342],[-79.833,43.39],[-79.83,43.425],[-79.818,43.47],[-79.809,43.52],[-79.806,43.56],[-79.808,43.578],[-79.794,43.606],[-79.764,43.619],[-79.722,43.656],[-79.68,43.696],[-79.664,43.722],[-79.64,43.752],[-79.6,43.768],[-79.557,43.782],[-79.535,43.79],[-79.483,43.802],[-79.46,43.818],[-79.42,43.834],[-79.367,43.852],[-79.3,43.866],[-79.24,43.874],[-79.199,43.879],[-79.15,43.899],[-79.105,43.915],[-79.04,43.93],[-78.96,43.944],[-78.88,43.955],[-78.8,43.968],[-78.72,43.982]]]
];

export interface SimCar {
  key: string; device: string; route: number; speedKmh: number; offsetKm: number; phaseMin: number;
  parkedAt: [number, number] | null; battery: number; power: boolean; odometer0: number;
}
export interface SimState { lat: number; lng: number; heading: number; speed: number; ignition: boolean; odometer: number; battery: number; power: boolean; fuel: number }

const DRIVE_MIN = 20, PARK_MIN = 4, CYCLE_MS = (DRIVE_MIN + PARK_MIN) * 60_000;
const R = 6371.0088;
const rad = (d: number) => (d * Math.PI) / 180;
export function km(a: [number, number], b: [number, number]): number {
  const dLat = rad(b[1] - a[1]), dLng = rad(b[0] - a[0]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}
function bearing(a: [number, number], b: [number, number]): number {
  const y = Math.sin(rad(b[0] - a[0])) * Math.cos(rad(b[1]));
  const x = Math.cos(rad(a[1])) * Math.sin(rad(b[1])) - Math.sin(rad(a[1])) * Math.cos(rad(b[1])) * Math.cos(rad(b[0] - a[0]));
  return (Math.round((Math.atan2(y, x) * 180) / Math.PI) + 360) % 360;
}
/** Each route's cumulative length, km. */
const LENGTHS = ROUTES.map(([, pts]) => { const c = [0]; for (let i = 1; i < pts.length; i++) c.push(c[i - 1]! + km(pts[i - 1]!, pts[i]!)); return c; });

/** A small, stable number from a text (FNV-1a), for the fleet's choices. */
export function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

/** The simulated fleet for these keys (car ids, or "SIM-0001"...): the same cars for the same keys. */
export function simFleet(keys: string[], speedingKmh = 140): SimCar[] {
  return keys.map((key, i) => {
    const h = hash(key);
    return {
      key, device: `SIM-${String(i + 1).padStart(4, '0')}`, route: (i + (h % 3)) % ROUTES.length,
      // car 2 is the one speeding; the rest between 62 and 108 km/h
      speedKmh: i === 1 ? speedingKmh + 8 : 62 + (h % 47), offsetKm: (h >>> 8) % 240, phaseMin: (h >>> 4) % (DRIVE_MIN + PARK_MIN),
      // the fourth car stays parked downtown (King and Bay)
      parkedAt: i === 3 ? [-79.3797, 43.6487] : null,
      battery: i === 2 ? 14 : 96 - ((h >>> 12) % 30), power: i !== 4, odometer0: 8000 + ((h >>> 16) % 90000)
    };
  });
}

/** Where a simulated car is at an instant (ms). */
export function simAt(c: SimCar, t: number): SimState {
  const fuel = (d: number) => Math.max(8, 92 - Math.round((d / 6) % 80));
  if (c.parkedAt) return { lng: c.parkedAt[0], lat: c.parkedAt[1], heading: 0, speed: 0, ignition: false, odometer: c.odometer0, battery: c.battery, power: c.power, fuel: 64 };
  const at = t + c.phaseMin * 60_000;
  const cycles = Math.floor(at / CYCLE_MS), inCycle = at - cycles * CYCLE_MS;
  const driving = inCycle < DRIVE_MIN * 60_000;
  const drivenMs = cycles * DRIVE_MIN * 60_000 + Math.min(inCycle, DRIVE_MIN * 60_000);
  const driven = (c.speedKmh * drivenMs) / 3_600_000;
  const cum = LENGTHS[c.route]!, pts = ROUTES[c.route]![1], len = cum[cum.length - 1]!;
  // back and forth along the highway
  let s = (c.offsetKm + driven) % (2 * len);
  const back = s > len;
  if (back) s = 2 * len - s;
  let i = 1;
  while (i < cum.length - 1 && cum[i]! < s) i++;
  const a = pts[i - 1]!, b = pts[i]!, seg = cum[i]! - cum[i - 1]!, f = seg > 0 ? (s - cum[i - 1]!) / seg : 0;
  const lng = a[0] + (b[0] - a[0]) * f, lat = a[1] + (b[1] - a[1]) * f;
  const heading = back ? bearing(b, a) : bearing(a, b);
  // a little life in the speed (the distance uses the car's steady speed)
  const speed = driving ? Math.max(0, Math.round(c.speedKmh + 4 * Math.sin(t / 47_000 + c.offsetKm))) : 0;
  return { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6, heading, speed, ignition: driving, odometer: Math.round((c.odometer0 + (driven % 5000)) * 10) / 10,
    battery: c.battery, power: c.power, fuel: fuel(driven) };
}

/** Points for the ingest's generic JSON, one every `stepS` seconds from `from` to `to` (ms), for every car. */
export function simPoints(cars: SimCar[], from: number, to: number, stepS = 10): Array<Record<string, unknown>> {
  const out: Array<Record<string, unknown>> = [];
  for (let t = from; t <= to; t += stepS * 1000) {
    for (const c of cars) {
      const s = simAt(c, t);
      out.push({ device: c.device, at: new Date(t).toISOString(), lat: s.lat, lng: s.lng, speed: s.speed, heading: s.heading, ignition: s.ignition,
        odometer: s.odometer, battery: s.battery, power: s.power, fuel: s.fuel });
    }
  }
  return out;
}

/** The trip a simulated car is on now (since its ignition came on), for demo mode. */
export function simTrip(c: SimCar, t: number): { started_at: string; km: number; max: number } | null {
  if (c.parkedAt) return null;
  const at = t + c.phaseMin * 60_000, inCycle = at % CYCLE_MS;
  if (inCycle >= DRIVE_MIN * 60_000) return null;
  return { started_at: new Date(t - inCycle).toISOString(), km: Math.round(((c.speedKmh * inCycle) / 3_600_000) * 10) / 10, max: c.speedKmh + 4 };
}
