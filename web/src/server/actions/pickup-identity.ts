'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { rolesOf, sessionAal } from '@/server/door';
import { storage } from '@/integrations/storage';
import { sha256Hex } from '@/server/links';
import { imageSniff } from '@/lib/file-sniff';
import { compareFace, readShown } from '@/server/pickup-identity';
import type { CheckDone, PickupView } from '@/features/pickup-identity/model';

// The pickup identity check (release 48 ops, 3292 and 3293): the person at the car against the renter on file. Field staff
// photograph the licence the person holds; a renter at the self check-in photographs their licence and takes a selfie.
// The photos are kept with the booking's ID images, read and compared on the server, and the database decides and keeps
// the result (and tells Fleet and Admin on a mismatch). Optional: nothing here is asked by, or stops, the handover.
// The payment card is never photographed: staff look at it and answer for its last four digits and its name.
type R<T> = { ok: true; data: T } | { ok: false; message: string };
const SR = { role: 'service_role' as const, skipViewAs: true };
const UUID = /^[0-9a-f-]{36}$/;
const msg = (e: unknown) => (e instanceof DbError ? e.message : e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Please try again.');

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const roles = await rolesOf(user.id);
  // staff keep their two-step rule; who may check which booking is decided by the database
  if ((roles.admin || roles.va || roles.field) && roles.two_step_required && (await sessionAal()) !== 'aal2') throw new Error('Two-step sign-in is required.');
  return user;
}

export async function pickupIdentityLoad(booking: string): Promise<R<PickupView>> {
  try {
    const user = await me();
    if (!UUID.test(booking)) return { ok: false, message: 'Unknown booking.' };
    const v = (await rpc('server_pickup_identity_view', { p_by: user.id, p_booking: booking }, SR)) as unknown as PickupView | null;
    return v ? { ok: true, data: v } : { ok: false, message: 'This check is for the staff handing the car over and the renter of the booking.' };
  } catch (e) { return { ok: false, message: msg(e) }; }
}

async function photo(form: FormData, name: string): Promise<{ bytes: Uint8Array; ext: string; mime: string } | null> {
  const file = form.get(name);
  if (!(file instanceof Blob) || file.size === 0) return null;
  if (file.size > 10 * 1024 * 1024) throw new Error('Each photo must be under 10 MB.');
  const bytes = new Uint8Array(await file.arrayBuffer());
  const { jpg, png } = imageSniff(bytes);
  if (!jpg && !png) throw new Error('That file is not a photo.');
  return { bytes, ext: jpg ? 'jpg' : 'png', mime: jpg ? 'image/jpeg' : 'image/png' };
}

/** One check: the photos taken now (front; back and selfie when given) and, from staff, the answers about the card shown. */
export async function pickupIdentityCheck(form: FormData): Promise<R<CheckDone>> {
  try {
    const user = await me();
    const booking = String(form.get('booking') ?? ''); const driver = String(form.get('driver') ?? '');
    if (!UUID.test(booking) || (driver && !UUID.test(driver))) return { ok: false, message: 'Unknown booking.' };
    const yn = (k: string) => { const v = String(form.get(k) ?? ''); return v === 'yes' || v === 'no' ? v : null; };
    const shots = { front: await photo(form, 'front'), back: await photo(form, 'back'), selfie: await photo(form, 'selfie') };
    const card = { last4: yn('card_last4'), name: yn('card_name') };
    if (!shots.front && !shots.selfie && !card.last4 && !card.name) return { ok: false, message: 'Take the photo of the licence first, or answer for the card.' };
    const s = await storage();
    const ids: Record<string, string> = {};
    let who = driver;
    for (const side of ['front', 'back', 'selfie'] as const) {
      const p = shots[side];
      if (!p) continue;
      const key = `pickup/${booking}/${side}-${crypto.randomUUID()}.${p.ext}`;
      await s.put('identity', key, p.bytes, p.mime);
      try {
        ids[side] = (await rpc('server_checkin_id_photo', { p_by: user.id, p: { booking, driver: driver || null, side, path: key, sha256: await sha256Hex(p.bytes), mime: p.mime } }, SR)) as unknown as string;
      } catch (e) { await s.remove('identity', key).catch(() => undefined); throw e; }
    }
    if (!who) {
      const v = (await rpc('server_pickup_identity_view', { p_by: user.id, p_booking: booking }, SR)) as unknown as PickupView | null;
      who = v?.drivers.find((d) => d.role === 'renter')?.driver_id ?? '';
    }
    const read = shots.front || shots.back ? await readShown(shots.front?.bytes ?? null, shots.back?.bytes ?? null) : null;
    // the face now: the selfie when there is one (the renter's own check-in), else the portrait on the licence shown
    const now = shots.selfie?.bytes ?? shots.front?.bytes ?? null;
    const face = now && who ? await compareFace(user.id, booking, who, now) : null;
    const done = (await rpc('server_pickup_identity_record', { p_by: user.id, p: { booking, driver: driver || null, id_upload: ids.front ?? null, selfie_upload: ids.selfie ?? null, read, face, card } }, SR)) as unknown as CheckDone;
    revalidatePath('/admin/bookings', 'layout'); revalidatePath('/staff/bookings', 'layout');
    return { ok: true, data: done };
  } catch (e) { return { ok: false, message: msg(e) }; }
}
