import 'server-only';
import { pushCard, pushPublicKey } from '@/server/push';
import { viewAs } from '@/server/view-as';
import { PushAlertsCard } from './PushAlertsCard';
import { PushPrompt } from './PushPrompt';
import type { PushRole } from './topics';

// Phone and browser alerts (migration 0300), for the server pages: nothing at all until the VAPID keys are set (or
// PUSH_PROVIDER=fake locally), and nothing while an Admin views a portal as someone else.

export async function PushAlerts({ userId, portal, className }: { userId: string; portal: PushRole; className?: string }) {
  if (await viewAs().catch(() => null)) return null;
  const card = await pushCard(userId);
  if (!card) return null;
  return <PushAlertsCard publicKey={card.publicKey} portal={portal} initial={card.state} className={className} />;
}

export async function PushInvite({ portal, home }: { portal: PushRole; home: string | string[] }) {
  if (await viewAs().catch(() => null)) return null;
  const key = await pushPublicKey().catch(() => null);
  return key ? <PushPrompt publicKey={key} portal={portal} home={home} /> : null;
}
