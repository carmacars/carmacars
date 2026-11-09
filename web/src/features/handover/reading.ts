// The odometer and fuel at every check-out and check-in (release 35, migration 0910): a dashboard photo (from the camera
// roll or the camera) read by the vision model, the person confirms "Odometer 45,210 km, fuel 3/4: correct?" or types the
// odometer and picks the fuel in eighths; a selfie in front of the car taken live with the device camera. Pure: the
// component, the server action, the read route and the unit tests share it. No imports.

/** The fuel gauge in eighths, stored as a whole percentage like the reports (an eighth is 12.5%). */
export const FUEL_EIGHTHS: ReadonlyArray<readonly [string, number]> = [
  ['Full', 100], ['7/8', 88], ['3/4', 75], ['5/8', 63], ['1/2', 50], ['3/8', 38], ['1/4', 25], ['1/8', 13], ['Empty', 0]
];
const WORDS = ['Empty', '1/8', '1/4', '3/8', '1/2', '5/8', '3/4', '7/8', 'Full'] as const;

export const eighthsToPct = (n: number): number => [0, 13, 25, 38, 50, 63, 75, 88, 100][Math.max(0, Math.min(8, Math.round(n)))]!;
export const pctToEighths = (pct: number): number => Math.max(0, Math.min(8, Math.round(pct / 12.5)));
export const fuelWords = (eighths: number): string => WORDS[Math.max(0, Math.min(8, Math.round(eighths)))]!;

/** The question the person answers after the photo is read. */
export function confirmQuestion(km: number, eighths: number): string {
  return `Odometer ${km.toLocaleString('en-CA')} km, fuel ${fuelWords(eighths)}: correct?`;
}

export interface DashRead { odometer_km: number | null; fuel_eighths: number | null }

/** What the model answered, checked: an odometer in whole km (miles converted), the fuel in eighths; anything unsure is null. */
export function dashFromModel(data: unknown): DashRead {
  const d = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>;
  const num = (v: unknown): number | null => {
    if (typeof v === 'number' && Number.isFinite(v)) return v;
    if (typeof v === 'string') { const s = v.replace(/[\s,]/g, '').replace(/(km|mi)$/i, ''); const n = Number(s); return s && Number.isFinite(n) ? n : null; }
    return null;
  };
  let km = num(d.odometer_km ?? d.odometer ?? d.km);
  const unit = String(d.unit ?? d.odometer_unit ?? 'km').toLowerCase();
  if (km !== null && /^mi/.test(unit)) km = km * 1.609344;
  if (km !== null && (km < 0 || km > 1_500_000)) km = null;
  if (km !== null) km = Math.round(km);
  let fuel: number | null = null;
  const f = d.fuel_eighths ?? d.fuel ?? d.fuel_level;
  const pct = num(typeof d.fuel_percent === 'string' ? d.fuel_percent.replace('%', '') : d.fuel_percent);
  if (pct !== null && pct >= 0 && pct <= 100) fuel = Math.round(pct / 12.5);
  else if (typeof f === 'string' && /^\s*\d\s*\/\s*\d\s*$/.test(f)) {
    const [a, b] = f.split('/').map((x) => Number(x.trim()));
    if (b) fuel = Math.round((a! / b) * 8);
  } else if (typeof f === 'string' && /^\s*(full|empty)\s*$/i.test(f)) fuel = /full/i.test(f) ? 8 : 0;
  else { const n = num(f); if (n !== null && Number.isInteger(n)) fuel = n; }
  if (fuel !== null && (fuel < 0 || fuel > 8)) fuel = null;
  const sure = d.readable === false || d.confidence === 'low' ? false : true;
  return sure ? { odometer_km: km, fuel_eighths: fuel } : { odometer_km: null, fuel_eighths: null };
}

export const DASH_SYSTEM = 'You read car dashboards. Answer only with JSON. Never guess: when a value cannot be read clearly, give null.';
export const DASH_PROMPT = 'This photo shows a car\'s instrument cluster. Read the odometer (the total distance, not a trip meter) and the fuel gauge. '
  + 'Answer as {"odometer": number or null, "unit": "km" or "mi", "fuel_eighths": whole number 0 to 8 or null, "readable": true or false}. '
  + 'fuel_eighths: 8 is full, 4 is half, 0 is empty. For an electric car give the battery percentage as "fuel_percent" instead.';

/** A selfie taken live: the camera's capture time (the file's time) within 10 minutes of now. */
export const SELFIE_FRESH_MS = 10 * 60_000;
export function selfieLive(capturedAtMs: number | null | undefined, nowMs: number = Date.now()): boolean {
  return typeof capturedAtMs === 'number' && Number.isFinite(capturedAtMs) && Math.abs(nowMs - capturedAtMs) <= SELFIE_FRESH_MS;
}

export interface ReadingState {
  dash: { bucket: string; path: string } | null;
  selfie: { bucket: string; path: string; taken_at: string | null; live: boolean; latitude: number | null; longitude: number | null } | null;
  ai: DashRead & { model: string | null } | null;
  /** the person said yes to the read values */
  confirmed: boolean;
  km: string;
  fuel: string;
}
export const emptyReading = (): ReadingState => ({ dash: null, selfie: null, ai: null, confirmed: false, km: '', fuel: '' });

/** The values sent: what was confirmed, else what was typed. */
export function readingValues(s: ReadingState): { odometer_km: string; fuel_pct: string; source: 'read_confirmed' | 'typed' } {
  if (s.confirmed && s.ai?.odometer_km !== null && s.ai?.odometer_km !== undefined && s.ai.fuel_eighths !== null) {
    return { odometer_km: String(s.ai.odometer_km), fuel_pct: String(eighthsToPct(s.ai.fuel_eighths)), source: 'read_confirmed' };
  }
  return { odometer_km: s.km.replace(/[\s,]/g, ''), fuel_pct: s.fuel, source: 'typed' };
}

/** What is still missing, in words the person reads; null when the reading is complete. */
export function readingProblem(s: ReadingState): string | null {
  if (!s.dash) return 'Add the photo of the dashboard (odometer and fuel gauge).';
  const v = readingValues(s);
  if (!/^\d{1,7}$/.test(v.odometer_km)) return 'Type the odometer in whole kilometres.';
  if (!FUEL_EIGHTHS.some(([, p]) => String(p) === v.fuel_pct)) return 'Pick the fuel level.';
  if (!s.selfie) return 'Take the selfie in front of the car with the camera.';
  return null;
}

/** The reading as the database keeps it (0910: app.handover_reading_record). */
export function readingPayload(s: ReadingState): Record<string, unknown> {
  const v = readingValues(s);
  return {
    source: v.source, ai_odometer_km: s.ai?.odometer_km ?? null, ai_fuel_eighths: s.ai?.fuel_eighths ?? null, ai_model: s.ai?.model ?? null,
    selfie: s.selfie ? { taken_at: s.selfie.taken_at, live: s.selfie.live, latitude: s.selfie.latitude, longitude: s.selfie.longitude } : null
  };
}

/** The two photos the reading adds to the report, tagged with their angles. */
export function readingPhotos(s: ReadingState): Array<{ bucket: string; path: string; angle: string }> {
  return [...(s.dash ? [{ ...s.dash, angle: 'dashboard' }] : []), ...(s.selfie ? [{ bucket: s.selfie.bucket, path: s.selfie.path, angle: 'selfie' }] : [])];
}

/** The server's check of what a check-out or check-in sends: the dashboard photo, the selfie, the odometer and the fuel. */
export function serverReadingProblem(p: { odometer_km?: string | null; fuel_pct?: string | null; photos: ReadonlyArray<{ angle?: string | null }> }): string | null {
  if (!p.photos.some((x) => x.angle === 'dashboard')) return 'Add the photo of the dashboard (odometer and fuel gauge).';
  if (!/^\d{1,7}$/.test(String(p.odometer_km ?? '').replace(/[\s,]/g, ''))) return 'Enter the odometer in whole kilometres.';
  if (!FUEL_EIGHTHS.some(([, x]) => String(x) === String(p.fuel_pct ?? ''))) return 'Pick the fuel level.';
  if (!p.photos.some((x) => x.angle === 'selfie')) return 'Take the selfie in front of the car with the camera.';
  return null;
}

/** The dashboard photo of a report side: the reading's own, else one tagged odometer or fuel, else the instrument cluster shot. */
export function pickDash<T extends { angle?: string | null; shot: string }>(photos: ReadonlyArray<T>): T | null {
  for (const want of ['dashboard', 'odometer', 'fuel']) { const p = photos.find((x) => x.angle === want); if (p) return p; }
  return photos.find((x) => x.shot === 'instrument_cluster') ?? null;
}

/** The return charges that come from the readings (the km over the allowance, the fuel or the charge). */
export const READING_CHARGE_KEYS = new Set(['mileage_overage', 'fuel', 'recharging', 'fuel_service_fee']);
