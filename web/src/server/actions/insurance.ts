'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { mergeParsed, parseClaimText, type Parsed } from '@/features/insurance/model';

// Insurance replacements (migration 5120), through the staff door (ops_do). The database decides who may do what (an
// Admin, Finance or customer service; money: Finance or an Admin) and checks everything again; its refusal is shown as
// written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const PAGES = ['/admin/insurance-replacements', '/staff/insurance-replacements', '/admin/insurers', '/admin/bookings', '/staff/bookings'];

export type InsuranceAction = 'insurer_rental_create' | 'insurer_rental_update' | 'insurer_rental_extend' | 'insurer_invoice_save' | 'insurer_invoice_send' | 'insurer_money' | 'draft_restore';

/** One write of Insurance replacements; the pages it changes are drawn again. */
export async function insuranceDo<T = Record<string, unknown>>(action: InsuranceAction, p: Record<string, unknown>): Promise<R<T>> {
  try {
    const { user, aal } = await me();
    const data = await door<T>(user.id, 'ops_do', action, p, aal);
    for (const x of PAGES) revalidatePath(x, 'layout');
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

const AI_SCHEMA = { type: 'object', properties: {
  renter_name: { type: 'string' }, renter_phone: { type: 'string' }, renter_email: { type: 'string' }, claim_number: { type: 'string' }, insurer_name: { type: 'string' },
  adjuster_name: { type: 'string' }, adjuster_email: { type: 'string' }, adjuster_phone: { type: 'string' }, pickup_date: { type: 'string' }, return_date: { type: 'string' },
  authorized_days: { type: 'integer' }, daily_rate_cents: { type: 'integer' }, car_year: { type: 'integer' }, car_make: { type: 'string' }, car_model: { type: 'string' }, car_plate: { type: 'string' } } };
const AI_SYSTEM = 'You read an email or notice from an auto insurer about a replacement rental car. Answer in JSON with only what the text clearly says: renter_name (the insured or claimant), renter_phone, renter_email, claim_number, insurer_name, adjuster_name, adjuster_email, adjuster_phone, pickup_date and return_date (YYYY-MM-DD), authorized_days, daily_rate_cents (the rate a day in cents), car_year, car_make, car_model, car_plate. Leave out anything not said. Never guess.';

/** Paste text: the rules first (pure, model.ts), then the AI for what they left empty. Nothing is saved: the form shows
 *  what was found for the person to check and use. */
export async function insuranceParse(text: string, insurers: string[]): Promise<R<{ found: Parsed; ai: boolean }>> {
  try {
    await me();
    const t = String(text ?? '').slice(0, 12_000);
    if (t.trim().length < 10) return { ok: false, code: 'refused', message: 'Paste the adjuster\'s email or the claim notice first.' };
    const rules = parseClaimText(t, insurers.slice(0, 200));
    let ai = false;
    let found = rules;
    try {
      const { textGenerator } = await import('@/integrations/llm');
      const gen = await textGenerator(undefined, 20_000);
      const r = await gen.generate<Record<string, unknown>>({ task: 'claim_read', maxOutputTokens: 300, temperature: 0, schema: AI_SCHEMA, system: AI_SYSTEM, prompt: `<text>\n${t}\n</text>` });
      if (r.ok && r.data && typeof r.data === 'object') { found = mergeParsed(rules, r.data); ai = JSON.stringify(found) !== JSON.stringify(rules); }
    } catch { /* the rules' reading stands */ }
    return { ok: true, data: { found, ai } };
  } catch (e) { return fail(e); }
}
