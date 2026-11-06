'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import { cookies } from 'next/headers';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal, VA_FN_COOKIE } from '@/server/door';

// 0545: the renter's own check-in at pickup (one screen), and staff's check-out or check-in on one screen.
type R<T> = { ok: true; data: T } | { ok: false; message: string };
const SR = { role: 'service_role' as const, skipViewAs: true };
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  let va: string | null = null;
  try { va = (await cookies()).get(VA_FN_COOKIE)?.value ?? null; } catch { va = null; }
  return { user, aal: await sessionAal(), va };
}
const msg = (e: unknown) => (e instanceof DbError ? e.message : e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Please try again or call us.');

export async function selfPickup(p: { number: string; at?: string; odometer_km?: string; fuel_pct?: string; note?: string; photos: Array<{ bucket: string; path: string; angle: string | null }> }): Promise<R<{ status: string; reason?: string }>> {
  try {
    const user = await requireUser(bookingPath(p.number));
    const b = await findBooking(user, p.number);
    if (!b) return { ok: false, message: 'Booking not found.' };
    const km = (p.odometer_km ?? '').replace(/[\s,]/g, '');
    if (km && !/^\d{1,7}$/.test(km)) return { ok: false, message: 'Enter the odometer in whole kilometres.' };
    const out = (await rpc('server_self_handover_submit' as never, { p_user: user.id, p: { booking: b.id, kind: 'pickup', at: p.at || null, odometer_km: km || null,
      fuel_pct: p.fuel_pct || null, note: p.note ?? '', photos: p.photos.map(({ bucket, path, angle }) => ({ bucket, path, angle })) } } as never, SR)) as unknown as { status: string; reason?: string };
    revalidatePath(bookingPath(p.number));
    return { ok: true, data: out };
  } catch (e) { return { ok: false, message: msg(e) }; }
}

export async function oneScreenHandover(p: { booking: string; kind: 'pickup' | 'return'; at?: string; odometer_km?: string; fuel_pct?: string; note?: string;
  photos: Array<{ bucket: string; path: string; angle: string | null }>; deposit_waiver_reason?: string; signature_override_reason?: string; refresh?: string[] }): Promise<R<{ report_id?: string; booking_status?: string }>> {
  try {
    const { user, aal, va } = await me();
    const km = (p.odometer_km ?? '').replace(/[\s,]/g, '');
    const r = await door<{ report_id?: string; booking_status?: string }>(user.id, 'ops_do', 'handover_one_screen', {
      booking: p.booking, kind: p.kind, at: p.at ? new Date(p.at).toISOString() : null, odometer_km: km || null, fuel_pct: p.fuel_pct || null, note: p.note ?? '',
      photos: p.photos, deposit_waiver_reason: p.deposit_waiver_reason || null, signature_override_reason: p.signature_override_reason || null, ...(va ? { _va: va } : {})
    }, aal);
    for (const x of p.refresh ?? []) revalidatePath(x);
    return { ok: true, data: r };
  } catch (e) { return { ok: false, message: msg(e) }; }
}
