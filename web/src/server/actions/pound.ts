'use server';
import { revalidatePath } from 'next/cache';
import { rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { maps } from '@/integrations/maps';
import type { TrackerEvents } from '@/features/tracking/events';

// Pound lots (migration 3320): the pin of each lot that has none, from its address through the site's address lookup
// (the address book first, Google within its daily cap). Admin only: the database's read says who manages the lots, and
// the write only fills pins that are empty.
export async function findPoundPins(refresh: string[] = []): Promise<ActionResult<{ asked: number; found: number }>> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, code: 'refused', message: 'Sign in first.' };
    const d = await door<TrackerEvents>(user.id, 'ops_read', 'tracker_events', {}, await sessionAal());
    if (!d.can.manage) return { ok: false, code: 'refused', message: 'Only an Admin changes the pound lots.' };
    const lots = d.lots.filter((l) => l.is_active && l.latitude == null).slice(0, 25);
    const m = await maps();
    const pins: Array<{ id: string; lat: number; lng: number }> = [];
    for (const l of lots) {
      const token = crypto.randomUUID();
      const s = (await m.autocomplete(l.address, token).catch(() => []))[0];
      const p = s ? await m.place(s.id, token).catch(() => null) : null;
      if (p && Number.isFinite(p.lat) && Number.isFinite(p.lng)) pins.push({ id: l.id, lat: p.lat, lng: p.lng });
    }
    const found = pins.length ? Number(await rpc('server_pound_lot_pins', { p: pins as unknown as Json }, { role: 'service_role' })) : 0;
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data: { asked: lots.length, found } };
  } catch (e) {
    return { ok: false, code: 'refused', message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' };
  }
}
