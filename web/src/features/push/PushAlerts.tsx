import 'server-only';
import { alertsAsk, nativePushConfig, pushCard, pushPublicKey } from '@/server/push';
import { appLinks } from '@/lib/site';
import { inAppShell } from '@/server/app-shell';
import { viewAs } from '@/server/view-as';
import { PushAlertsCard } from './PushAlertsCard';
import { PushPrompt } from './PushPrompt';
import type { PushRole } from './topics';

// Phone and browser alerts (migration 0300), for the server pages: nothing at all until the VAPID keys are set (or
// PUSH_PROVIDER=fake locally), and nothing while an Admin views a portal as someone else. In the store app (0390) the
// card and the invitation use the phone's own alerts and need the Firebase service account instead of the VAPID keys.

export async function PushAlerts({ userId, portal, className }: { userId: string; portal: PushRole; className?: string }) {
  if (await viewAs().catch(() => null)) return null;
  const card = await pushCard(userId, await inAppShell());
  if (!card) return null;
  return <PushAlertsCard publicKey={card.publicKey} native={card.native} portal={portal} initial={card.state} className={className} />;
}

// 0523: the database says when this person must be asked whatever the device remembers (an owner once approved, staff at
// their first sign-in); on a phone browser that cannot show alerts, the store app's link when it is set.
export async function PushInvite({ portal, home, userId }: { portal: PushRole; home: string | string[]; userId?: string }) {
  if (await viewAs().catch(() => null)) return null;
  const ask = userId ? await alertsAsk(userId) : null;
  if (await inAppShell()) return nativePushConfig() ? <PushPrompt publicKey={null} native portal={portal} home={home} ask={ask} /> : null;
  const [key, apps] = await Promise.all([pushPublicKey().catch(() => null), appLinks()]);
  return key || apps.ios || apps.android ? <PushPrompt publicKey={key} portal={portal} home={home} ask={ask} apps={apps} /> : null;
}
