import './whats-new.css';
import type { WnPortal } from '@/lib/whats-new';
import { whatsNewFor } from '@/server/whats-new';
import { WhatsNewClient } from './WhatsNewClient';

// "What's new" (release 43; migration 2730): the link in each portal's menu, and the pop-up that opens by itself once on a
// person's next visit after a release that has words for their portal. The words are the release note's "For <portal>"
// section (docs/releases, scripts/whats-new.mjs); the database keeps who has seen which release (user_release_seen).
export async function WhatsNew({ portal, userId, className = 'btn btn--quiet btn--sm gd-link hd-act' }: { portal: WnPortal; userId: string; className?: string }) {
  const s = await whatsNewFor(userId, portal).catch(() => null);
  if (!s) return null;
  return <WhatsNewClient portal={portal} release={s.latest.release} date={s.latest.date} summary={s.latest.summary} items={s.latest.items} autoOpen={s.autoOpen} className={className} />;
}
