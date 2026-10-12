import 'server-only';
import { env } from '@/lib/env';

// VIN decoding for the owner wizard. NHTSA vPIC (free, no key) in production; sample answers locally.
// The answer is stored once per VIN (public.server_record_vin_decode), in the shape the listing worker uses.
export interface VinDecode { ok: boolean; year?: string; make?: string; model?: string; trim?: string; body_class?: string; fuel?: string; drivetrain?: string; transmission?: string; doors?: string; seats?: string; engine?: string; error_code?: string; raw?: Record<string, unknown> }

const FUEL: Record<string, string> = { gasoline: 'gasoline', diesel: 'diesel', electric: 'electric', 'plug-in hybrid': 'plug_in_hybrid', hybrid: 'hybrid' };
const fuelOf = (primary: string, electrification: string) => {
  const e = electrification.toLowerCase();
  if (e.includes('phev') || e.includes('plug-in')) return 'plug_in_hybrid';
  if (e.includes('hev') || e.includes('hybrid')) return 'hybrid';
  return FUEL[primary.toLowerCase()] ?? (primary.toLowerCase().includes('electric') ? 'electric' : '');
};

const SAMPLES: Record<string, VinDecode> = {
  '1HG': { ok: true, year: '2021', make: 'Honda', model: 'Civic', trim: 'EX', body_class: 'Sedan', fuel: 'gasoline' },
  '2T1': { ok: true, year: '2022', make: 'Toyota', model: 'Corolla', trim: 'LE', body_class: 'Sedan', fuel: 'gasoline' },
  '5YJ': { ok: true, year: '2023', make: 'Tesla', model: 'Model 3', body_class: 'Sedan', fuel: 'electric' },
  'WDD': { ok: true, year: '2022', make: 'Mercedes-Benz', model: 'C 300', body_class: 'Sedan', fuel: 'gasoline' }
};

export async function decodeVin(vin: string): Promise<{ provider: string; result: VinDecode }> {
  if (env().VIN_DECODER === 'fake') return { provider: 'fake', result: SAMPLES[vin.slice(0, 3)] ?? { ok: false, error_code: 'unknown_sample' } };
  try {
    const r = await fetch(`https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/${encodeURIComponent(vin)}?format=json`, { signal: AbortSignal.timeout(6000) });
    const j = (await r.json()) as { Results?: Array<Record<string, string>> };
    const x = j.Results?.[0] ?? {};
    const year = x.ModelYear ?? '', make = x.Make ?? '', model = x.Model ?? '';
    return { provider: 'vpic', result: {
      ok: !!(year && make && model), year, make: make.length <= 3 ? make : make.toLowerCase().replace(/\b[a-z]/g, (c) => c.toUpperCase()), model, trim: x.Trim ?? '', body_class: x.BodyClass ?? '',
      fuel: fuelOf(x.FuelTypePrimary ?? '', x.ElectrificationLevel ?? ''), drivetrain: x.DriveType ?? '', transmission: x.TransmissionStyle ?? '',
      doors: x.Doors ?? '', seats: x.Seats ?? '', engine: [x.DisplacementL && `${x.DisplacementL} L`, x.EngineCylinders && `${x.EngineCylinders} cylinders`].filter(Boolean).join(', '),
      error_code: x.ErrorCode ?? undefined, raw: x
    } };
  } catch {
    return { provider: 'vpic', result: { ok: false, error_code: 'unreachable' } };
  }
}
