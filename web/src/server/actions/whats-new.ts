'use server';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import { isWnPortal, showFor } from '@/lib/whats-new';
import { WN_DATA } from '@/server/whats-new';

/** The pop-up was shown to the person: it will not open by itself again (it is still one click away in the menu). */
export async function markReleaseSeen(portal: string, release: string): Promise<{ ok: boolean }> {
  try {
    const user = await currentUser();
    if (!user || !isWnPortal(portal) || !showFor(WN_DATA, release, portal)) return { ok: false };
    if (await viewAs()) return { ok: true };
    await rpc('release_seen_mark', { p_release: release, p_portal: portal, p_by: user.id }, { role: 'service_role' });
    return { ok: true };
  } catch { return { ok: false }; }
}
