import 'server-only';
import { nativePushConfig, pushCard, pushPublicKey } from '@/server/push';
import { inAppShell } from '@/server/app-shell';
import { viewAs } from '@/server/view-as';
import { PushAlertsCard } from './PushAlertsCard';
import { PushPrompt, type PushMoment } from './PushPrompt';
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

export async function PushInvite({ portal, home, moment }: { portal: PushRole; home: string | string[]; moment?: PushMoment }) {
  if (await viewAs().catch(() => null)) return null;
  if (await inAppShell()) return nativePushConfig() ? <PushPrompt publicKey={null} native portal={portal} home={home} moment={moment} /> : null;
  const key = await pushPublicKey().catch(() => null);
  return key ? <PushPrompt publicKey={key} portal={portal} home={home} moment={moment} /> : null;
}
