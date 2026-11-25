'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import { door } from '@/server/door';
import { requireOwnerUser } from '@/server/owner/data';
import type { ActionResult } from '@/features/forms/schemas';

// The owner pipeline (r50, 4511): the two steps an owner records on their own car, the ServiceOntario appointment and the
// visit done. The database checks the car is theirs and the values (app.owner_stage_do).
type Op = { op: 'appointment'; at: string; place: string } | { op: 'visited'; fees_paid: boolean; fees_note?: string };

export async function ownerStageAct(vehicleId: string, p: Op): Promise<ActionResult<null>> {
  if (!/^[0-9a-f-]{36}$/.test(vehicleId)) return { ok: false, code: 'invalid', message: 'Unknown car.' };
  try {
    const user = await requireOwnerUser();
    await door(user.id, 'ops_do', 'owner_stage_do', { vehicle_id: vehicleId, ...p });
    revalidatePath('/owner'); revalidatePath(`/owner/vehicles/${vehicleId}`);
    return { ok: true, data: null };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Something went wrong. Please try again or call us.' };
  }
}
