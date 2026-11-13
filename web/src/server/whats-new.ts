import 'server-only';
import { rpc } from '@/lib/db/repo';
import { headers } from 'next/headers';
import { viewAs } from '@/server/view-as';
import { latestFor, pickPopup, type WnData, type WnPortal, type WnShow } from '@/lib/whats-new';
import generated from '@/generated/whats-new.json';

// The "What's new" pop-up as the portal frames read it: the text is built into the site (scripts/whats-new.mjs); the
// database says which releases this person has seen in this portal (migration 2730). Nothing is written while an Admin views as.
export const WN_DATA = generated as unknown as WnData;

export interface WnState { latest: WnShow; autoOpen: boolean }

export async function whatsNewFor(userId: string, portal: WnPortal): Promise<WnState | null> {
  const latest = latestFor(WN_DATA, portal);
  if (!latest) return null;
  if (await viewAs().catch(() => null)) return { latest, autoOpen: false };
  // The end-to-end suite sends this header so the pop-up never covers the page under other tests (playwright.config.ts);
  // tests/e2e/whats-new.spec.ts sends none. It only stops the pop-up opening by itself, never the link.
  if ((await headers().catch(() => null))?.get('x-cc-whats-new') === 'quiet') return { latest, autoOpen: false };
  let seen: string[] = [];
  try { seen = ((await rpc('release_seen_list', { p_by: userId, p_portal: portal }, { role: 'service_role' })) as unknown as string[] | null) ?? []; } catch { return { latest, autoOpen: false }; }
  return { latest, autoOpen: pickPopup(WN_DATA, portal, seen) !== null };
}
