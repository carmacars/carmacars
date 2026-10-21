import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage, type Bucket } from '@/integrations/storage';
import { decodeVin } from '@/integrations/vin';
import { visionModel } from '@/integrations/vision';
import { COLOUR_PROMPT, COLOUR_SYSTEM, colourFromAnswer } from '@/features/vin/vin';

// The car details that come after the car is added (migration 0079), run by the listing worker's five-minute tick and
// right after a car is added: a VIN the decoder could not read is decoded again (the car fills itself), and a car with
// no colour gets it from its cover photo (Workers AI vision; the database says which cars, which model and whether
// today's allowance has room, and keeps a person's colour).
const SR = { role: 'service_role' as const };

function base64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const mimeOf = (b: Uint8Array) => (b[0] === 0x89 && b[1] === 0x50 ? 'image/png' : b[0] === 0xff && b[1] === 0xd8 ? 'image/jpeg' : b[8] === 0x57 && b[9] === 0x45 ? 'image/webp' : null);

export interface CarDetailsSummary { decoded: number; filled: number; colours: number; errors: string[] }

export async function runCarDetailsNow(o: { vins?: number; colours?: number } = {}): Promise<CarDetailsSummary> {
  const sum: CarDetailsSummary = { decoded: 0, filled: 0, colours: 0, errors: [] };
  // 1. VINs decoded later
  try {
    const due = (await rpc('server_vin_decode_due', { p_limit: o.vins ?? 3 }, SR)) as unknown as Array<{ vin: string }>;
    for (const { vin } of due ?? []) {
      const d = await decodeVin(vin);
      await rpc('server_record_vin_decode', { p_vin: vin, p_provider: d.provider, p_output: d.result as unknown as Json }, SR);
      if (d.result.ok) { sum.decoded++; sum.filled += Number(await rpc('server_vin_decoded_apply', { p_vin: vin }, SR)) || 0; }
    }
  } catch (e) { sum.errors.push(`vin: ${e instanceof Error ? e.message.slice(0, 200) : 'failed'}`); }
  // 2. the colour from the cover photo
  try {
    const due = (await rpc('server_colour_read_due', { p_limit: o.colours ?? 2 }, SR)) as unknown as {
      allowed: boolean; model?: string; fallback_model?: string | null; cars: Array<{ vehicle_id: string; photo_id: string; bucket: Bucket; path: string }> };
    if (due?.allowed && due.cars.length) {
      const s = await storage();
      const vision = await visionModel();
      for (const c of due.cars) {
        const t0 = Date.now();
        const bytes = await s.get(c.bucket, c.path).catch(() => null);
        const mime = bytes ? mimeOf(bytes) : null;
        if (!bytes || !mime || bytes.length > 3_000_000) {
          await rpc('server_colour_read_record', { p: { vehicle_id: c.vehicle_id, photo_id: c.photo_id, ok: false, model: 'none', error: bytes ? 'The cover photo is too large or not an image' : 'The cover photo was not found' } as unknown as Json }, SR);
          continue;
        }
        const r = await vision.read({ purpose: 'colour_read', system: COLOUR_SYSTEM, prompt: COLOUR_PROMPT, imageDataUrl: `data:${mime};base64,${base64(bytes)}`, maxOutputTokens: 60 },
          [due.model ?? '', due.fallback_model ?? ''].filter(Boolean));
        const colour = r.ok ? colourFromAnswer(r.data) : null;
        const out = (await rpc('server_colour_read_record', { p: {
          vehicle_id: c.vehicle_id, photo_id: c.photo_id, ok: r.ok, colour, model: r.model ?? r.tried[r.tried.length - 1] ?? 'unknown',
          neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0, error: r.ok ? (colour ? null : 'No clear colour in the answer') : `${r.reason}: ${r.message}`
        } as unknown as Json }, SR)) as unknown as { set: boolean };
        if (out?.set) sum.colours++;
      }
    }
  } catch (e) { sum.errors.push(`colour: ${e instanceof Error ? e.message.slice(0, 200) : 'failed'}`); }
  return sum;
}
