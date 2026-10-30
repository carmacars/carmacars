'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import type { ActionResult } from '@/features/forms/schemas';
import { bookingPath } from '@/features/portal/status';
import { door, sessionAal } from '@/server/door';
import { currentUser, findBooking, requireUser } from '@/server/portal/data';

// Add-ons (migration 0066): the catalogue (an Admin edits it, Fleet sets stock), staff confirming or removing an
// add-on on a booking, and the renter adding one after booking from their portal, paid on the Card on File.
// The database checks who may do what, the notice, the stock and the cutoff; its refusal is shown as written.
type R<T = null> = ActionResult<T>;
const SR = { role: 'service_role' as const };
const fail = (e: unknown, fallback = 'Something went wrong. Please try again or call us.'): { ok: false; code: string; message: string } =>
  ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : fallback });

interface ChargeFacts { booking_addon_id: string; booking_id: string; booking_number: string; name: string; status: string; amount_cents: number; paid: boolean;
  card: { method_id: string; customer_id: string; brand: string | null; last4: string | null } | null; charge_now?: boolean }

async function staff() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

/** Charge an add-on bought after booking on the Card on File and record it; with no card (or a decline when staff
 *  confirm it), the add-on waits unpaid and Finance collects it. Returns a message for the person, or null. */
async function settle(f: ChargeFacts, record: (processor: Record<string, unknown> | null, amount: number | null) => Promise<{ ok?: boolean; message?: string }>,
  onDecline: (message: string) => Promise<void>): Promise<string | null> {
  if (f.amount_cents <= 0 || !f.card?.method_id || !f.card.customer_id) {
    const r = await record(null, null);
    return r.ok === false ? (r.message ?? 'Not added.') : f.amount_cents > 0 ? 'No card on file: press Pay for your add-ons to pay for it by card.' : null;
  }
  const i = await (await payments()).chargeOffSession({ customerId: f.card.customer_id, paymentMethodId: f.card.method_id, amountCents: f.amount_cents,
    description: `${f.name} for ${f.booking_number}`, metadata: { booking_id: f.booking_id, booking_addon_id: f.booking_addon_id, purpose: 'addon' },
    idempotencyKey: `addon:${f.booking_addon_id}` });
  if (i.status !== 'succeeded') { const m = i.lastError ?? 'The card was declined. Nothing was charged.'; await onDecline(m); return m; }
  const r = await record({ processor: 'stripe', payment_id: i.id, charge_id: i.chargeId }, i.amountCents);
  return r.ok === false ? (r.message ?? 'The payment could not be recorded.') : null;
}

// ---------------------------------------------------------------- the renter
export async function buyAddon(number: string, choice: { code: string; quantity?: number; hours?: number | null }): Promise<R<{ status: string; message: string | null }>> {
  try {
    const user = await requireUser(bookingPath(number));
    const b = await findBooking(user, number);
    if (!b) return fail(null, 'Booking not found');
    const f = (await rpc('server_booking_addon_buy', { p_booking: b.id, p_by: user.id, p: { code: choice.code, quantity: choice.quantity ?? 1, hours: choice.hours ?? null } }, SR)) as unknown as ChargeFacts;
    if (f.status === 'pending') { revalidatePath(bookingPath(number)); return { ok: true, data: { status: 'pending', message: null } }; }
    const msg = await settle(f,
      async (processor, amount) => (await rpc('server_booking_addon_paid', { p_row: f.booking_addon_id, p_by: user.id, p_processor: processor as never, p_amount_cents: amount as never }, SR)) as unknown as { ok?: boolean; message?: string },
      async (m) => { await rpc('server_booking_addon_failed', { p_row: f.booking_addon_id, p_by: user.id, p_reason: m }, SR); });
    revalidatePath(bookingPath(number));
    if (msg && f.card?.method_id) return fail(new Error(msg));
    return { ok: true, data: { status: f.status, message: msg } };
  } catch (e) { return fail(e); }
}

// ---------------------------------------------------------------- staff
export async function staffAddonConfirm(id: string, ok: boolean, note?: string, refresh: string[] = []): Promise<R<{ message: string | null }>> {
  try {
    const { user, aal } = await staff();
    const f = await door<ChargeFacts>(user.id, 'ops_do', 'booking_addon_confirm', { id, ok, note: note ?? null }, aal);
    let message: string | null = null;
    if (ok && f.charge_now) {
      message = await settle(f,
        async (processor, amount) => door(user.id, 'ops_do', 'booking_addon_paid', { id, processor, amount_cents: amount }, aal),
        // a decline when staff confirm: it stays confirmed, unpaid, and Finance collects it
        async () => { await door(user.id, 'ops_do', 'booking_addon_paid', { id, processor: null, amount_cents: null }, aal); });
    }
    for (const p of refresh) revalidatePath(p);
    return { ok: true, data: { message } };
  } catch (e) { return fail(e); }
}

export async function staffAddonRemove(id: string, reason: string, refresh: string[] = []): Promise<R<{ refund_id: string | null }>> {
  try {
    const { user, aal } = await staff();
    const r = await door<{ refund_id: string | null }>(user.id, 'ops_do', 'booking_addon_remove', { id, reason }, aal);
    for (const p of refresh) revalidatePath(p);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** Admin: any field of an add-on (a new one without id). Fleet: { id, stock_count } only. */
export async function saveAddon(p: Record<string, unknown>): Promise<R<Record<string, unknown>>> {
  try {
    const { user, aal } = await staff();
    const r = await door<Record<string, unknown>>(user.id, 'ops_do', 'addon_save', p, aal);
    revalidatePath('/admin/settings/addons'); revalidatePath('/staff/addons');
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** Admin: an add-on's photo (JPEG or WebP, up to 4 MB) in the public bucket; then its path on the add-on. */
export async function uploadAddonPhoto(form: FormData): Promise<R<{ path: string }>> {
  try {
    const { user, aal } = await staff();
    const id = String(form.get('id') ?? '');
    const file = form.get('file');
    if (!/^[0-9a-f-]{36}$/.test(id)) return fail(null, 'Save the add-on first.');
    if (!(file instanceof File) || file.size === 0) return fail(null, 'Choose a photo.');
    if (file.size > 4_000_000) return fail(null, 'The photo must be under 4 MB.');
    const bytes = new Uint8Array(await file.arrayBuffer());
    const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8;
    const webp = String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP';
    if (!jpeg && !webp) return fail(null, 'Use a JPEG or WebP photo.');
    const { randomUUID } = await import('node:crypto');
    const key = `addons/${randomUUID()}.${jpeg ? 'jpg' : 'webp'}`;
    const { storage } = await import('@/integrations/storage');
    const s = await storage();
    await s.put('vehicle-public', key, bytes, jpeg ? 'image/jpeg' : 'image/webp');
    if (s.name === 'local') {
      const { mkdir, writeFile } = await import('node:fs/promises');
      const path = await import('node:path');
      const target = path.join(/* turbopackIgnore: true */ process.cwd(), 'public/_local/vehicle-public', key);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, bytes);
    }
    await door(user.id, 'ops_do', 'addon_save', { id, photo_path: key }, aal);
    revalidatePath('/admin/settings/addons');
    return { ok: true, data: { path: key } };
  } catch (e) { return fail(e); }
}
