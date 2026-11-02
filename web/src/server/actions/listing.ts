'use server';
import { after } from 'next/server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { runListingWorkerNow } from '@/server/listing-worker';

// The listing pipeline's screens (migration 0032, through the door's ops calls): start a listing, see the
// capture and the progress, submit, retry a step. Who may do what is the database's (app.user_may_list):
// an owner for their own car, field staff for a car of their job, Fleet and Admins for any car, customer
// service to review. After a submit or a retry the worker runs once right away, after the response.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

function kick() {
  after(async () => { try { await runListingWorkerNow({ maxJobs: 40, deadlineMs: 25_000 }); } catch { /* the cron sweep picks it up */ } });
}

export async function listingStart(p: { vehicle_id?: string; vin?: string; plate?: string; colour?: string; odometer_km?: number; notes?: string }): Promise<R<{ intake_id: string; state: string; existing: boolean }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ intake_id: string; state: string; existing: boolean }>(user.id, 'ops_do', 'listing_start', p, aal);
    kick();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingSubmit(intake: string, refresh: string[] = []): Promise<R<{ state: string }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ state: string }>(user.id, 'ops_do', 'listing_submit', { intake }, aal);
    kick();
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingRetryJob(job: string, refresh: string[] = []): Promise<R<{ status: string; state: string }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ status: string; state: string }>(user.id, 'ops_do', 'listing_job_retry', { job }, aal);
    kick();
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function listingProgress<T = Record<string, unknown>>(intakes: string[]): Promise<R<Record<string, T>>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<Record<string, T>>(user.id, 'ops_read', 'listing_progress', { intakes: intakes.slice(0, 200) }, aal) };
  } catch (e) { return fail(e); }
}

export async function listingCapture<T = Record<string, unknown>>(intake: string): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<T>(user.id, 'ops_read', 'listing_capture', { intake }, aal) };
  } catch (e) { return fail(e); }
}

/** 0521: the listing page's four steps (Photos, Cover plates, Review, Live on the site). */
export async function listingSteps<T = Record<string, unknown>>(intake: string): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<T>(user.id, 'ops_read', 'listing_steps', { intake }, aal) };
  } catch (e) { return fail(e); }
}

/** 0521: a photo filed under the wrong shot taken off (kept privately); the shot is free for the right photo. */
export async function listingPhotoRemove(photo: string, refresh: string[] = []): Promise<R<{ photo_id: string; shot: string; missing: string[] }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ photo_id: string; shot: string; missing: string[] }>(user.id, 'ops_do', 'listing_photo_remove', { photo }, aal);
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

/** R23 (0236): the newest handover's photos (the check-out or check-in photos field staff took) become the car's listing
 *  photos: each copied into the listing intake as if taken on the capture screen, then the intake is submitted when every
 *  required shot is there, so the studio editor runs and the listing review follows as usual. */
export async function listingFromHandover(vehicleId: string, refresh: string[] = []): Promise<R<{ intake_id: string; copied: number; missing: string[]; submitted: boolean }>> {
  try {
    const { user, aal } = await me();
    if (!/^[0-9a-f-]{36}$/i.test(vehicleId)) throw new Error('Unknown car.');
    const set = await door<{ photos: Array<{ shot_type: string; bucket: string; path: string; width: number | null; height: number | null }> }>(user.id, 'ops_read', 'handover_listing_photos', { vehicle: vehicleId }, aal);
    if (!set.photos.length) throw new Error('This car has no handover photos of the listing shots yet.');
    const start = await door<{ intake_id: string; state: string }>(user.id, 'ops_do', 'listing_start', { vehicle_id: vehicleId }, aal);
    const { storage } = await import('@/integrations/storage');
    const { sha256Hex } = await import('@/server/links');
    const s = await storage();
    let copied = 0;
    let last: { missing: string[]; complete: boolean } = { missing: [], complete: false };
    for (const ph of set.photos) {
      if (ph.bucket !== 'condition-photos') continue;
      const bytes = await s.get('condition-photos', ph.path);
      if (!bytes) continue;
      const png = bytes[0] === 0x89 && bytes[1] === 0x50;
      const key = `vehicles/${vehicleId}/original/${start.intake_id}/${ph.shot_type}-handover-${crypto.randomUUID().slice(0, 8)}.${png ? 'png' : 'jpg'}`;
      await s.put('vehicle-originals', key, bytes, png ? 'image/png' : 'image/jpeg');
      try {
        last = await door<{ missing: string[]; complete: boolean }>(user.id, 'ops_do', 'listing_upload', { intake: start.intake_id, shot_type: ph.shot_type, original_path: key,
          width: ph.width, height: ph.height, byte_size: bytes.length, mime_type: png ? 'image/png' : 'image/jpeg', sha256: await sha256Hex(bytes) }, aal);
        copied++;
      } catch (e) {
        await s.remove('vehicle-originals', key).catch(() => undefined);
        if (!copied) throw e;
      }
    }
    let submitted = false;
    if (copied && last.complete) { await door(user.id, 'ops_do', 'listing_submit', { intake: start.intake_id }, aal); submitted = true; kick(); }
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data: { intake_id: start.intake_id, copied, missing: last.missing ?? [], submitted } };
  } catch (e) { return fail(e); }
}
