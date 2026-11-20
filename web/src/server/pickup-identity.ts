import 'server-only';
import { rpc } from '@/lib/db/repo';
import { visionModel } from '@/integrations/vision';
import { storage } from '@/integrations/storage';
import { LICENCE_PROMPT, LICENCE_SCHEMA, LICENCE_SYSTEM, fieldsFromModel, parseAamva, type LicenceFields } from '@/features/licence/aamva';
import { decodeImage, readPdf417, shrink, smallJpegDataUrl, type Rgba } from '@/features/licence/barcode';
import { faceAnswer } from '@/features/pickup-identity/model';

// The reading behind the pickup identity check (3293). The licence shown at the pickup is read here, on the server: the
// back's barcode when there is one, else the vision model within the day's allowance. The face is compared with the
// photo on file by the same model. Both run under the purpose licence_read, which is never sent to Gemini (identity
// documents stay on the private providers). Nothing read is logged, and nothing here writes to the licence on file:
// app.pickup_identity_record compares and keeps the result. A model that does not answer leaves "not checked".
const SR = { role: 'service_role' as const };
export type Read = { name: string | null; number: string | null; expiry: string | null };
const FACE_SYSTEM = 'You compare two photos placed side by side and answer in JSON. Never name or describe anyone. Answer "different" only when the two are clearly different people. When a face is small, blurred, covered, or you cannot tell, answer "unsure".';
const FACE_PROMPT = 'The left photo and the right photo each show a person (a photo of a person, or the portrait printed on a driver\'s licence). Are they the same person? Return {"same_person": "same" | "different" | "unsure", "confidence": 0 to 100}.';
const FACE_SCHEMA = { type: 'object', properties: { same_person: { type: 'string' }, confidence: { type: 'number' } } };

async function models(): Promise<string[] | null> {
  const gate = (await rpc('server_licence_read_gate', {}, SR)) as unknown as { allowed: boolean; model?: string; fallback_model?: string | null };
  return gate?.allowed && gate.model ? [gate.model, gate.fallback_model ?? ''].filter(Boolean) : null;
}
const nameOf = (f: LicenceFields) => f.full_name ?? ([f.first_name, f.last_name].filter(Boolean).join(' ') || null);

/** What is printed on the licence shown: from the back's barcode, else from the front by the vision model. */
export async function readShown(front: Uint8Array | null, back: Uint8Array | null): Promise<Read | null> {
  try {
    const b = back ? decodeImage(back) : null;
    const text = b ? readPdf417(b) : null;
    const coded = text ? parseAamva(text) : null;
    if (coded) return { name: nameOf(coded), number: coded.licence_number, expiry: coded.expires_on };
    const img = front ? decodeImage(front) : null;
    const use = img ? await models() : null;
    if (!img || !use) return null;
    const r = await (await visionModel()).read({ purpose: 'licence_read', imageDataUrl: smallJpegDataUrl(img), system: LICENCE_SYSTEM, prompt: LICENCE_PROMPT, schema: LICENCE_SCHEMA, maxOutputTokens: 300 }, use);
    if (!r.ok) return null;
    const m = fieldsFromModel(r.data);
    if (m.quality !== 'ok') return null;
    return { name: nameOf(m.fields), number: m.fields.licence_number, expiry: m.fields.expires_on };
  } catch (e) {
    console.error('pickup identity read', e instanceof Error ? e.name : 'error');
    return null;
  }
}

/** Two photos on one canvas, left and right, each at most `side` pixels. */
export function sideBySide(a: Rgba, b: Rgba, side = 640): Rgba {
  const l = shrink(a, side), r = shrink(b, side);
  const gap = 16, width = l.width + gap + r.width, height = Math.max(l.height, r.height);
  const data = new Uint8Array(width * height * 4).fill(255);
  const put = (s: Rgba, x0: number) => { for (let y = 0; y < s.height; y++) data.set(s.data.subarray(y * s.width * 4, (y + 1) * s.width * 4), (y * width + x0) * 4); };
  put(l, 0); put(r, l.width + gap);
  return { width, height, data };
}

/** Is the face in the photo taken now the face on file? "unsure" whenever the model cannot say, and it then flags nothing. */
export async function compareFace(by: string, booking: string, driver: string, now: Uint8Array): Promise<'same' | 'different' | 'unsure' | null> {
  try {
    const src = (await rpc('server_pickup_identity_source', { p_by: by, p_booking: booking, p_driver: driver }, SR)) as unknown as { bucket: string; path: string } | null;
    if (!src?.path) return null;
    const file = await (await storage()).get('identity', src.path);
    const a = file ? decodeImage(file) : null, b = decodeImage(now);
    const use = a && b ? await models() : null;
    if (!a || !b || !use) return null;
    const r = await (await visionModel()).read({ purpose: 'licence_read', imageDataUrl: smallJpegDataUrl(sideBySide(a, b), 1296), system: FACE_SYSTEM, prompt: FACE_PROMPT, schema: FACE_SCHEMA, maxOutputTokens: 60 }, use);
    return r.ok ? faceAnswer(r.data) : null;
  } catch (e) {
    console.error('pickup identity face', e instanceof Error ? e.name : 'error');
    return null;
  }
}
