'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { encryptField, PAYOUT_KEY_VERSION } from '@/server/crypto';
import type { Bucket } from '@/integrations/storage/types';

// Supply types, partners, rentals added by hand, retiring and deleting cars (migration 0046), through the staff door.
// The database decides who may do what (Admins; customer service and Sales add rentals within their limits) and
// checks everything again; its refusal is shown as written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const PUBLIC = ['/cars/[slug]', '/cars', '/', '/rent/[hub]', '/sitemap.xml'];
function rebuild(paths: string[]) {
  for (const p of paths) {
    if (p.includes('[')) revalidatePath(p, 'page');
    else if (p === '/') revalidatePath('/', 'layout');
    else revalidatePath(p);
  }
}

export type SupplyRead = 'supply_settings' | 'partners' | 'partner' | 'vehicle_delete_blockers' | 'vehicle_delete_preview' | 'sample_cars' | 'manual_rental_renters' | 'manual_rental_quote' | 'manual_rental_vehicles' | 'bookings_by_supply';
export async function supplyRead<T = Record<string, unknown>>(what: SupplyRead, p: Record<string, unknown> = {}): Promise<R<T>> {
  try { const { user, aal } = await me(); return { ok: true, data: await door<T>(user.id, 'ops_read', what, p, aal) }; } catch (e) { return fail(e); }
}

/** One action of 0046 that needs nothing from the server but the door (partner record, supply, commission, retire, restore). */
export async function supplyDo<T = Record<string, unknown>>(action: 'partner_save' | 'vehicle_add' | 'vehicle_set_supply' | 'vehicle_set_commission' | 'vehicle_retire' | 'vehicle_restore' | 'verify_driver_in_person' | 'partner_payout_verify',
  p: Record<string, unknown> = {}, refresh: string[] = []): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const data = await door<T>(user.id, 'ops_do', action, p, aal);
    rebuild([...refresh, ...(action === 'vehicle_retire' || action === 'vehicle_restore' ? PUBLIC : [])]);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

type Files = Array<{ bucket: Bucket; path: string }>;
async function removeFiles(files: Files): Promise<number> {
  if (!files.length) return 0;
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  let n = 0;
  for (const f of files) { try { await s.remove(f.bucket, f.path); n++; } catch { /* a file already gone */ } }
  return n;
}

/** Delete a car with nothing tied to money: the database deletes the records, then its photo files go from storage. */
export async function deleteVehicle(vehicleId: string, confirm: string): Promise<R<{ files: number }>> {
  try {
    const { user, aal } = await me();
    const r = await door<{ files: Files }>(user.id, 'ops_do', 'vehicle_delete', { vehicle_id: vehicleId, confirm }, aal);
    const n = await removeFiles(r.files ?? []);
    rebuild(['/admin/vehicles', ...PUBLIC]);
    return { ok: true, data: { files: n } };
  } catch (e) { return fail(e); }
}

/** Delete every sample car that meets the rule; the others stay, each with why. */
export async function deleteSampleCars(confirm: string): Promise<R<{ deleted: number; kept: Array<{ name: string; why: string }>; files: number; requests_removed: Array<{ booking_number: string }> }>> {
  try {
    const { user, aal } = await me();
    const r = await door<{ deleted: number; kept: Array<{ name: string; why: string }>; files: Files; requests_removed?: Array<{ booking_number: string }> }>(user.id, 'ops_do', 'vehicles_delete_samples', { confirm }, aal);
    const n = await removeFiles(r.files ?? []);
    rebuild(['/admin/vehicles', '/admin', ...PUBLIC]);
    return { ok: true, data: { deleted: r.deleted, kept: r.kept, files: n, requests_removed: r.requests_removed ?? [] } };
  } catch (e) { return fail(e); }
}

export interface ManualRentalResult { booking_id: string; booking_number: string; status: string; total_cents: number; due_cents: number; blocks_calendar: boolean;
  charge?: { customer_id: string; method_id: string; amount_cents: number; brand: string; last4: string } | null; card?: { ok: boolean; message?: string };
  /** The saved card is charged when the renter signs (the legal review, 0053), never when staff add the rental. */
  charge_on_sign?: boolean;
  /** The choice and a price typed by hand (0058). */
  sales_choice?: 'sourced' | 'for_carmacars' | null; sales_sourced?: boolean; price_flags?: string[]; rate_sheet_cents?: number | null }

/** Add a rental. With the saved card, nothing is charged here: the renter's "Accept and sign" charges it (0053). */
export async function createManualRental(p: Record<string, unknown>): Promise<R<ManualRentalResult>> {
  try {
    const { user, aal } = await me();
    const r = await door<ManualRentalResult>(user.id, 'ops_do', 'manual_rental_create', p, aal);
    if (r.charge?.method_id && r.charge.customer_id && r.charge.amount_cents > 0) {
      const { payments } = await import('@/integrations/payments');
      let ok = false; let message: string | undefined;
      try {
        const i = await (await payments()).chargeOffSession({ customerId: r.charge.customer_id, paymentMethodId: r.charge.method_id, amountCents: r.charge.amount_cents,
          description: `Rental ${r.booking_number}`, metadata: { booking_id: r.booking_id, purpose: 'booking_total', manual_rental: 'true' }, idempotencyKey: `manual-rental:${r.booking_id}` });
        ok = i.status === 'succeeded';
        message = ok ? undefined : i.lastError ?? 'The card was declined.';
        await door(user.id, 'ops_do', 'manual_rental_card_result', { booking: r.booking_id, ok, amount_cents: i.amountCents || r.charge.amount_cents, error: message,
          processor: { payment_id: i.id, charge_id: i.chargeId } }, aal);
      } catch (e) {
        message = e instanceof Error ? e.message : 'The card could not be charged.';
        await door(user.id, 'ops_do', 'manual_rental_card_result', { booking: r.booking_id, ok: false, amount_cents: r.charge.amount_cents, error: message }, aal).catch(() => undefined);
      }
      r.card = { ok, message };
      r.charge = null;
    }
    rebuild(['/admin/bookings', '/admin/calendar', '/va/requests', '/va/my-sales', '/field/sales', '/cars/[slug]']);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

/** A partner's payout account (Admins): the account number is encrypted here before it is stored, like an owner's. */
export async function savePartnerPayout(form: FormData): Promise<R<{ id: string }>> {
  const method = String(form.get('method') ?? 'bank_transfer');
  const account = String(form.get('account_no') ?? '').replace(/\D/g, '');
  try {
    const { user, aal } = await me();
    const p = method === 'e_transfer'
      ? { method, account_holder: String(form.get('account_holder') ?? ''), e_transfer_email: String(form.get('e_transfer_email') ?? '') }
      : { method, account_holder: String(form.get('account_holder') ?? ''), institution_no: String(form.get('institution_no') ?? ''), transit_no: String(form.get('transit_no') ?? ''),
          account_no: account.length >= 5 ? await encryptField(account) : '', account_last4: account.slice(-4), key_version: PAYOUT_KEY_VERSION };
    const r = await door<{ id: string }>(user.id, 'ops_do', 'partner_payout_account', { partner_id: String(form.get('partner_id') ?? ''), ...p }, aal);
    revalidatePath('/admin/partners');
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}
