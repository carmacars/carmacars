import 'server-only';
import { rpc } from '@/lib/db/repo';
import { visionModel } from '@/integrations/vision';
import { LICENCE_PROMPT, LICENCE_SCHEMA, LICENCE_SYSTEM, fieldsFromModel, parseAamva, retakeMessage, type LicenceFields, type Quality } from '@/features/licence/aamva';
import { decodeImage, readPdf417, smallJpegDataUrl } from '@/features/licence/barcode';

// The driver's licence reader (release 31, D2; migration 0602): every licence photo uploaded (the renter's verify page and
// booking request, an additional driver's own link, staff at the counter or in the field) is read here, on the server,
// once it is stored and registered. The back's PDF417 barcode first (barcode.ts, pure JavaScript), else the vision model
// within the day's AI allowance (purpose licence_read). The database records the read (staff only), fills the driver's
// empty licence fields, runs the checks, applies the Ontario rule for the main driver and, when an Admin turned it on,
// approves automatically. Nothing read is logged: an error is logged by its name only.
export type Side = 'licence_front' | 'licence_back';
export interface ReadOutcome { read: boolean; retake: string | null; primaryMoved: boolean }
const SR = { role: 'service_role' as const };
const NONE: ReadOutcome = { read: false, retake: null, primaryMoved: false };

type Who = { booking_id: string; driver_id: string } | { signer_id: string };

export async function readLicence(who: Who, side: string, bytes: Uint8Array): Promise<ReadOutcome> {
  if (side !== 'licence_front' && side !== 'licence_back') return NONE;
  try {
    const img = decodeImage(bytes);
    if (!img) return NONE;
    let fields: LicenceFields | null = null;
    let source: 'barcode' | 'vision' = 'vision';
    let quality: Quality = 'unreadable';
    let model: string | null = null; let neurons = 0; let ms = 0; let error: string | null = null;
    if (side === 'licence_back') {
      const text = readPdf417(img);
      const f = text ? parseAamva(text) : null;
      if (f) { fields = f; source = 'barcode'; quality = 'ok'; }
    }
    if (!fields) {
      const gate = (await rpc('server_licence_read_gate', {}, SR)) as unknown as { allowed: boolean; model?: string; fallback_model?: string | null };
      // no allowance left today: staff read it themselves, as before
      if (!gate?.allowed || !gate.model) return NONE;
      const t0 = Date.now();
      const r = await (await visionModel()).read({ purpose: 'licence_read', imageDataUrl: smallJpegDataUrl(img), system: LICENCE_SYSTEM, prompt: LICENCE_PROMPT,
        schema: LICENCE_SCHEMA, maxOutputTokens: 300 }, [gate.model, gate.fallback_model ?? ''].filter(Boolean));
      ms = Date.now() - t0; model = r.model ?? r.tried[r.tried.length - 1] ?? gate.model; neurons = r.usage?.neurons ?? 0;
      if (!r.ok) {
        // the model did not answer: no read recorded beyond the call, and the renter is not asked to take it again
        await rpc('server_licence_read_record', { p: { ...who, side, source: 'none', quality: 'unreadable', model, neurons, duration_ms: ms, error: r.reason, call_only: true } }, SR).catch(() => undefined);
        return NONE;
      }
      const m = fieldsFromModel(r.data);
      fields = m.fields; quality = m.quality;
      if (m.side === 'back' && side === 'licence_front' && quality === 'ok') error = 'back uploaded as the front';
    }
    const res = (await rpc('server_licence_read_record', { p: { ...who, side, source, quality, model, neurons, duration_ms: ms, error, ...fields } }, SR)) as unknown as { primary?: string | null };
    return { read: true, retake: retakeMessage(quality, side), primaryMoved: res?.primary === 'needed' };
  } catch (e) {
    console.error('licence read', e instanceof Error ? e.name : 'error');
    return NONE;
  }
}
