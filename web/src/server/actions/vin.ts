'use server';
import { DbError, rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import type { ActionResult } from '@/features/forms/schemas';
import { cleanVin, VIN_RE, type DecodedCar } from '@/features/vin/vin';
import { decodeVin, modelsFor } from '@/integrations/vin';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';

// VIN-first entry for staff (migration 0082): Admin > Add a car and Add a car for an owner (an Admin, customer service,
// fleet). One call at the 17th character: the decode on file, or vPIC now (recorded once per VIN, so a VIN is never
// decoded twice), the check digit, a car already in the fleet, the class and the daily rate the car starts from.
const SR = { role: 'service_role' as const };
type R<T> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

export interface ClassHint { class: string; why: string; rule: string | null }
export interface RateHint { daily_cents: number; source: 'similar' | 'class'; text: string }
export interface VinFacts {
  vin: string; valid: boolean; check_ok?: boolean; decode: DecodedCar | null; decode_failed_at?: string | null;
  taken: { vehicle_id: string; name: string; supply: string; retired: boolean; is_sample: boolean } | null;
  class: ClassHint | null; rates: RateHint | null;
}

async function staff(): Promise<void> {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const r = await rolesOf(user.id);
  if (!r.admin && !(r.va_functions ?? (r.va ? [r.va] : [])).some((f) => f === 'cs' || f === 'fleet')) throw new Error('An Admin, customer service or fleet adds cars.');
}

const facts = async (vin: string) => (await rpc('server_vin_facts', { p_vin: vin }, SR)) as unknown as VinFacts;

/** Everything the form shows for a VIN. Decodes with vPIC when no decode is on file (and none failed in the last hour). */
export async function vinFacts(raw: string): Promise<R<VinFacts>> {
  const vin = cleanVin(raw ?? '');
  if (!VIN_RE.test(vin)) return { ok: false, code: 'invalid', message: 'A VIN is 17 letters and digits, never I, O or Q.', fieldErrors: { vin: 'A VIN is 17 letters and digits, never I, O or Q.' } };
  try {
    await staff();
    let f = await facts(vin);
    const recentFail = f.decode_failed_at && Date.now() - new Date(f.decode_failed_at).getTime() < 3_600_000;
    if (!f.decode && !recentFail) {
      const d = await decodeVin(vin);
      await rpc('server_record_vin_decode', { p_vin: vin, p_provider: d.provider, p_output: d.result as unknown as Json }, SR);
      f = await facts(vin);
    }
    return { ok: true, data: f };
  } catch (e) { return fail(e); }
}

/** The class and the starting daily rate for year, make and model typed by hand (no decode), or a class chosen. */
export async function vinClassHint(p: { year?: number | string; make?: string; model?: string; trim?: string; body?: string; class?: string }): Promise<R<{ class: ClassHint; rates: RateHint }>> {
  try {
    await staff();
    return { ok: true, data: (await rpc('server_vin_class_hint', { p: p as unknown as Json }, SR)) as unknown as { class: ClassHint; rates: RateHint } };
  } catch (e) { return fail(e); }
}

/** The models of a make in a model year, for the fallback list (owners use it too: it only asks the public decoder). */
export async function vinModels(make: string, year: number): Promise<R<string[]>> {
  if (!make || !(year >= 1980 && year <= 2100)) return { ok: true, data: [] };
  return { ok: true, data: await modelsFor(make.slice(0, 40), year) };
}
