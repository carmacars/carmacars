import 'server-only';
import { rpc } from '@/lib/db/repo';
import { visionModel } from '@/integrations/vision';
import { SORT_PROMPT, SORT_SYSTEM, fileAs, parseSort } from '@/features/listing/photo-sort';

// "Add photos" sorts each photo to its shot with the vision model (release 28, migration 0566), within the day's AI share:
// the capture screen's upload route and the Google Drive import (src/server/drive-import.ts) both file a photo this way.
export interface SortRecord { watermark: boolean; model?: string; neurons?: number; ok: boolean; ms: number }

const b64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };

/** The largest photo the vision model is sent (a data URL); a larger one is sorted from a smaller copy (drive-import.ts). */
export const SORT_MAX_BYTES = 3_400_000;

/** The shot a photo is filed under, given the shots the car already has; the model is asked only when the day's AI share allows. */
export async function sortShot(by: string, bytes: Uint8Array, type: string, taken: ReadonlySet<string>): Promise<{ shot: string; sort: SortRecord }> {
  const t0 = Date.now();
  let parsed: ReturnType<typeof parseSort> = null;
  let model: string | undefined; let neurons = 0; let ok = false;
  const gate = (await rpc('server_photo_sort_gate', { p_by: by }, { role: 'service_role' }).catch(() => null)) as unknown as { allowed?: boolean; model?: string; fallback_model?: string | null } | null;
  if (gate?.allowed && gate.model && bytes.length < SORT_MAX_BYTES) {
    const r = await (await visionModel()).read({ purpose: 'photo_sort', imageDataUrl: `data:${type};base64,${b64(bytes)}`, system: SORT_SYSTEM, prompt: SORT_PROMPT,
      schema: { type: 'object' }, maxOutputTokens: 60 }, [gate.model, gate.fallback_model ?? ''].filter(Boolean)).catch(() => null);
    if (r) { ok = r.ok; model = r.model; neurons = r.usage?.neurons ?? 0; if (r.ok) parsed = parseSort(r.data); }
  }
  const f = fileAs(parsed, taken);
  return { shot: f.shot, sort: { watermark: f.watermark, model, neurons, ok, ms: Date.now() - t0 } };
}

/** What the model cost and saw, kept with the photo (a watermark it saw flags the photo). */
export async function recordSort(by: string, sort: SortRecord, photoId: string): Promise<void> {
  await rpc('server_photo_sort_record', { p_by: by, p: { model: sort.model ?? null, ok: sort.ok, neurons: sort.neurons ?? 0, duration_ms: sort.ms, watermark: sort.watermark, photo_id: photoId } }, { role: 'service_role' }).catch(() => undefined);
}
