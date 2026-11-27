import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { areaOf } from '@/features/academy/gate';
import { helpFor } from '@/features/help/routes';

// 5171: a staff member stuck on a page (the Stuck? prompt shown, or repeated errors there) gets that page's academy section
// (the help map's lesson), required before they continue that area. The database decides (staff only, one open a section,
// none again for 7 days after a pass, the error count) and tells the person.
export async function assignStuck(userId: string, route: string, tab: string | null | undefined, reason: string): Promise<void> {
  const h = helpFor(route, tab);
  if (!h?.lesson || (h.portal !== 'va' && h.portal !== 'field')) return;
  const area = areaOf(h.pattern);
  if (!/^\/staff(\/[a-z0-9_-]+)*$/.test(area)) return;
  await rpc('academy_assign_stuck', { p_by: userId, p: { area, lesson: h.lesson, reason } as unknown as Json }, { role: 'service_role' }).catch(() => undefined);
}
