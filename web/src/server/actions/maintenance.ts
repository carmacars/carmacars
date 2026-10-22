'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import type { CarMaintenance } from '@/features/maintenance/model';

// The maintenance tracker's actions (migration 0089), through the door's ops calls: the same for an Admin, Fleet and
// Finance. The database checks the person and the rule; its refusal is shown as written.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });

async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

function refresh(vehicleId?: string) {
  for (const p of ['/admin/maintenance', '/va/maintenance', '/admin', '/va']) revalidatePath(p);
  if (vehicleId) { revalidatePath(`/admin/vehicles/${vehicleId}`); revalidatePath(`/va/vehicles/${vehicleId}`); }
}

/** One car's maintenance, for the pop-up opened from the overview (it loads when opened). */
export async function maintCar(vehicleId: string): Promise<R<CarMaintenance>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<CarMaintenance>(user.id, 'ops_read', 'maint_vehicle', { vehicle_id: vehicleId }, aal) };
  } catch (e) { return fail(e); }
}

const MAX = 15_000_000;
/** Record a service in one step: the work, the date and odometer, the shop, the cost, who pays, billed or not, and the
 *  receipt (PDF, JPEG or PNG; stored in the private documents bucket first). The database makes the bill and resets
 *  each item's timer in the same transaction. */
export async function recordService(form: FormData): Promise<R<{ id: string; billing_status: string }>> {
  try {
    const { user, aal } = await me();
    let p: Record<string, unknown>;
    try { p = JSON.parse(String(form.get('p') ?? '{}')) as Record<string, unknown>; } catch { return { ok: false, code: 'invalid', message: 'Something went wrong with the form. Try again.' }; }
    const file = form.get('receipt');
    if (file instanceof File && file.size > 0) {
      if (file.size > MAX) return { ok: false, code: 'invalid', message: 'The receipt must be under 15 MB.' };
      const bytes = new Uint8Array(await file.arrayBuffer());
      const pdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
      const jpg = bytes[0] === 0xff && bytes[1] === 0xd8;
      const png = bytes[0] === 0x89 && bytes[1] === 0x50;
      if (!pdf && !jpg && !png) return { ok: false, code: 'invalid', message: 'The receipt must be a PDF, JPEG or PNG file.' };
      const [type, ext] = pdf ? ['application/pdf', 'pdf'] : jpg ? ['image/jpeg', 'jpg'] : ['image/png', 'png'];
      const key = `maintenance/${new Date().getUTCFullYear()}/${crypto.randomUUID()}.${ext}`;
      const { storage } = await import('@/integrations/storage');
      await (await storage()).put('documents', key, bytes, type!);
      const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
      p.receipt = { storage_path: key, mime_type: type, sha256: Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join(''), title: file.name.slice(0, 200) };
    }
    const data = await door<{ id: string; billing_status: string }>(user.id, 'ops_do', 'maint_record', p, aal);
    refresh(String(p.vehicle_id ?? ''));
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
