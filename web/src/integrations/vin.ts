import 'server-only';
import { env } from '@/lib/env';
import { chooseGearbox, epaGearbox, mapVpic, type Gearbox, type VinDecode } from '@/features/vin/vin';

// VIN decoding for every place a car is added and for the listing worker. NHTSA vPIC (free, no key) in production;
// sample answers locally (VIN_DECODER=fake). The answer is stored once per VIN (public.server_record_vin_decode), in the
// shape the listing worker uses; the mapping is src/features/vin/vin.ts (mapVpic, unit tested).
export type { VinDecode };

// The fake decoder's cars, by the first three characters (the maker's code). Tests and local work use VINs with a
// valid check digit: WP1AB2A56GLB12345 (Porsche Macan), 1G6AX5SX5F0123456 (Cadillac CTS), 1FM5K8D87LGA12345 (Ford
// Explorer), 2HGFC2F59KH123456 (Honda Civic). A maker's code that is not listed (ZZZ...) is "not decoded".
const SAMPLES: Record<string, VinDecode> = {
  '1HG': { ok: true, year: '2021', make: 'Honda', model: 'Civic', trim: 'EX', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'FWD/Front-Wheel Drive', transmission: 'Continuously Variable Transmission (CVT)', doors: '4', seats: '5', engine: '1.5 L, 4 cylinders, turbo' },
  '2HG': { ok: true, year: '2019', make: 'Honda', model: 'Civic', trim: 'LX', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'FWD/Front-Wheel Drive', transmission: 'Continuously Variable Transmission (CVT)', doors: '4', seats: '5', engine: '2.0 L, 4 cylinders' },
  '2T1': { ok: true, year: '2022', make: 'Toyota', model: 'Corolla', trim: 'LE', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'FWD/Front-Wheel Drive', transmission: 'Continuously Variable Transmission (CVT)', doors: '4', seats: '5', engine: '1.8 L, 4 cylinders' },
  '5YJ': { ok: true, year: '2023', make: 'Tesla', model: 'Model 3', trim: 'Long Range', body_class: 'Sedan/Saloon', fuel: 'electric', drivetrain: 'AWD/All-Wheel Drive', transmission: 'Automatic', doors: '4', seats: '5' },
  WDD: { ok: true, year: '2022', make: 'Mercedes-Benz', model: 'C-Class', trim: 'C300 4MATIC', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'AWD/All-Wheel Drive', transmission: 'Automatic, 9 speeds', doors: '4', seats: '5', engine: '2.0 L, 4 cylinders, turbo' },
  W1K: { ok: true, year: '2021', make: 'Mercedes-Benz', model: 'S-Class', trim: 'S580 4MATIC', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'AWD/All-Wheel Drive', transmission: 'Automatic, 9 speeds', doors: '4', seats: '5', engine: '4.0 L, V8, turbo' },
  WP1: { ok: true, year: '2016', make: 'Porsche', model: 'Macan', trim: 'S', body_class: 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)', fuel: 'gasoline', drivetrain: 'AWD/All-Wheel Drive', transmission: 'Automatic, 7 speeds', doors: '5', seats: '5', engine: '3.0 L, V6, turbo' },
  '1G6': { ok: true, year: '2015', make: 'Cadillac', model: 'CTS', trim: 'Luxury', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'AWD/All-Wheel Drive', transmission: 'Automatic, 8 speeds', doors: '4', seats: '5', engine: '2.0 L, 4 cylinders, turbo' },
  '1FM': { ok: true, year: '2020', make: 'Ford', model: 'Explorer', trim: 'XLT', body_class: 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)', fuel: 'gasoline', drivetrain: '4WD/4-Wheel Drive/4x4', transmission: 'Automatic, 10 speeds', doors: '4', seats: '7', engine: '2.3 L, 4 cylinders, turbo' },
  KNA: { ok: true, year: '2015', make: 'Kia', model: 'Forte', trim: 'LX', body_class: 'Sedan/Saloon', fuel: 'gasoline', drivetrain: 'FWD/Front-Wheel Drive', transmission: 'Automatic, 6 speeds', doors: '4', seats: '5', engine: '1.8 L, 4 cylinders' }
};

export async function decodeVin(vin: string): Promise<{ provider: string; result: VinDecode }> {
  if (env().VIN_DECODER === 'fake') return { provider: 'fake', result: SAMPLES[vin.slice(0, 3)] ?? { ok: false, error_code: 'unknown_sample' } };
  try {
    const r = await fetch(`https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/${encodeURIComponent(vin)}?format=json`, { signal: AbortSignal.timeout(6000) });
    const j = (await r.json()) as { Results?: Array<Record<string, string>> };
    const x = j.Results?.[0] ?? {};
    const result = mapVpic(x);
    // the gearbox (0094): vPIC often fills one in by default; EPA's data for the model decides, vPIC only when explicit
    if (result.ok) {
      const g = chooseGearbox(await epaFor(Number(result.year), result.make ?? '', result.model ?? ''), { style: String(x.TransmissionStyle ?? '').trim(), speeds: String(x.TransmissionSpeeds ?? '').trim() });
      result.transmission = g.gearbox ?? '';
      result.raw = { ...(result.raw ?? {}), _transmission_source: g.source };
    }
    return { provider: 'vpic', result };
  } catch {
    return { provider: 'vpic', result: { ok: false, error_code: 'unreachable' } };
  }
}

const FAKE_MODELS: Record<string, string[]> = {
  honda: ['Accord', 'Civic', 'CR-V', 'HR-V', 'Odyssey', 'Pilot'], toyota: ['Camry', 'Corolla', 'Highlander', 'RAV4', 'Sienna'], ford: ['Escape', 'Explorer', 'F-150', 'Mustang'],
  porsche: ['911', 'Cayenne', 'Macan', 'Panamera', 'Taycan'], cadillac: ['CT5', 'CTS', 'Escalade', 'XT5'], 'mercedes-benz': ['C-Class', 'E-Class', 'GLC', 'GLE', 'S-Class']
};
const modelCache = new Map<string, string[]>();
/** The models a make sold in a model year (vPIC GetModelsForMakeYear), for the fallback list; [] when unknown. */
export async function modelsFor(make: string, year: number): Promise<string[]> {
  const key = `${make.toLowerCase()}|${year}`;
  if (env().VIN_DECODER === 'fake') return FAKE_MODELS[make.toLowerCase()] ?? [];
  if (modelCache.has(key)) return modelCache.get(key)!;
  try {
    const r = await fetch(`https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/${encodeURIComponent(make)}/modelyear/${year}?format=json`, { signal: AbortSignal.timeout(6000) });
    const names = new Set<string>();
    if (r.ok) {
      const j = (await r.json()) as { Results?: Array<{ Model_Name?: string }> };
      for (const m of j.Results ?? []) if (m.Model_Name?.trim()) names.add(m.Model_Name.trim());
    }
    const out = [...names].sort((a, b) => a.localeCompare(b));
    if (out.length) modelCache.set(key, out);
    return out;
  } catch { return []; }
}

// ---------------------------------------------------------------- EPA (fueleconomy.gov), for the gearbox (0094)
const EPA = 'https://www.fueleconomy.gov/ws/rest/vehicle/menu';
type MenuItem = { text?: string; value?: string };
async function epaMenu(path: string): Promise<MenuItem[]> {
  const r = await fetch(`${EPA}/${path}`, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(5000) });
  if (!r.ok) return [];
  const j = (await r.json().catch(() => null)) as { menuItem?: MenuItem | MenuItem[] } | null;
  const m = j?.menuItem;
  return Array.isArray(m) ? m : m ? [m] : [];
}
/** EPA's gearbox for a year, make and model: its own model name, or the models that start with it ("GLA-Class": GLA250,
 *  GLA45); null when EPA does not know the car or cannot be reached. */
export async function epaFor(year: number, make: string, model: string): Promise<Gearbox | 'mixed' | null> {
  if (!year || !make || !model) return null;
  try {
    const q = (m: string) => epaMenu(`options?year=${year}&make=${encodeURIComponent(make)}&model=${encodeURIComponent(m)}`);
    let texts = (await q(model)).map((o) => o.text ?? '');
    if (!texts.length) {
      const base = model.replace(/-class$/i, '').toLowerCase();
      const models = (await epaMenu(`model?year=${year}&make=${encodeURIComponent(make)}`)).map((o) => o.value ?? '').filter((m) => m.toLowerCase().startsWith(base)).slice(0, 4);
      for (const m of models) texts = texts.concat((await q(m)).map((o) => o.text ?? ''));
    }
    return epaGearbox(texts);
  } catch { return null; }
}
