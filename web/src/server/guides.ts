import 'server-only';
import { rpc } from '@/lib/db/repo';
import { viewAs } from '@/server/view-as';
import type { SessionUser } from '@/lib/auth';

// The guides of migration 0044, as the portals read them: the published guide (HTML rendered once at publish), the
// stored PDF and the reader's state. One database read per page; the page writes nothing while an Admin views as.
const SR = { role: 'service_role' as const };
export type GuidePortal = 'renter' | 'owner' | 'admin' | 'va' | 'field' | 'investor';
export const GUIDE_PORTALS: GuidePortal[] = ['renter', 'owner', 'admin', 'va', 'field', 'investor'];
export const GUIDE_PATH: Record<GuidePortal, string> = { renter: '/account/guide', owner: '/owner/guide', admin: '/admin/guide', va: '/va/guide', field: '/field/guide', investor: '/investor/guide' };
export const GUIDE_NAME: Record<GuidePortal, string> = { renter: 'Renter', owner: 'Owner', admin: 'Admin', va: 'VA', field: 'Field', investor: 'Investor' };
export const isGuidePortal = (p: string): p is GuidePortal => (GUIDE_PORTALS as string[]).includes(p);

export interface GuideData {
  portal: GuidePortal; title: string; promise: string | null; signin_url: string; lands_on: string | null; version: number; published_at: string | null;
  sections: Array<{ id: string; slug: string; kind: 'start' | 'chapter' | 'reference'; title: string; blurb: string | null; html: string }>;
  pdf: { id: string; generated_at: string; source: string; bytes: number; pages: number | null; guide_version: number | null; stale: boolean } | null;
  reader: { last_version: number | null; last_opened_at: string | null; banner_dismissed_at: string | null } | null;
}

/** The published guide for this person; records that they opened it (not while an Admin views as them). */
export async function guideFor(user: SessionUser, portal: GuidePortal, record = true): Promise<GuideData> {
  const data = (await rpc('guide_read', { p_by: user.id, p_portal: portal }, SR)) as unknown as GuideData;
  if (record && data.version > 0 && !(await viewAs())) {
    await rpc('guide_opened', { p_by: user.id, p_portal: portal }, SR).catch(() => undefined);
  }
  return data;
}

/** Whether the first-visit banner shows for this person and portal. */
export async function guideBanner(userId: string, portal: GuidePortal): Promise<boolean> {
  if (await viewAs()) return false;
  return (await rpc('guide_banner', { p_by: userId, p_portal: portal }, SR).catch(() => false)) === true;
}
