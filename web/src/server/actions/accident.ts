'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { requireUser } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';

// Release 35 (migration 0912): the renter reports an accident from the accident card, and adds photos or videos after.
type R<T> = { ok: true; data: T } | { ok: false; message: string };
const SR = { role: 'service_role' as const, skipViewAs: true };
const msg = (e: unknown) => (e instanceof DbError ? e.message : e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong. Call us.');

export interface AccidentSent { incident_id: string; incident_number: string; media: number; phone: string | null; roadside_phone: string | null; report_hours: number; drivable: boolean; anyone_hurt: boolean }

export async function renterAccidentReport(number: string, p: Record<string, unknown>): Promise<R<AccidentSent>> {
  try {
    const user = await requireUser(bookingPath(number));
    const out = (await rpc('server_renter_accident_report' as never, { p_by: user.id, p } as never, SR)) as unknown as AccidentSent;
    revalidatePath(bookingPath(number));
    return { ok: true, data: out };
  } catch (e) { return { ok: false, message: msg(e) }; }
}

export async function renterAccidentMedia(number: string, incident: string, media: Array<{ bucket: string; path: string }>): Promise<R<{ added: number }>> {
  try {
    const user = await requireUser(bookingPath(number));
    const out = (await rpc('server_renter_accident_media' as never, { p_by: user.id, p: { incident, media } } as never, SR)) as unknown as { added: number };
    return { ok: true, data: out };
  } catch (e) { return { ok: false, message: msg(e) }; }
}
