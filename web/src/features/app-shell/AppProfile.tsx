import 'server-only';
import { rpc } from '@/lib/db/repo';
import { inAppShell } from '@/server/app-shell';
import { viewAs } from '@/server/view-as';
import { AppUnlockCard } from './AppUnlockCard';
import { DeleteAccountCard } from './DeleteAccountCard';
import type { DeletionState } from './deletion';

// The profile's app part (migration 0390), next to Phone alerts: App lock (Face ID or fingerprint, in the store app only)
// and Delete my account (renters, owners and investors, in the app and on the site). Nothing while an Admin views a
// portal as someone else.
const SR = { role: 'service_role' as const };

export async function AppProfile({ userId, lock = false, deletion = false, className }: { userId: string; lock?: boolean; deletion?: boolean; className?: string }) {
  if (await viewAs().catch(() => null)) return null;
  const app = lock && (await inAppShell());
  let state: DeletionState | null = null;
  if (deletion) {
    try { state = (await rpc('server_account_deletion_state', { p_user: userId }, SR)) as unknown as DeletionState; } catch { state = null; }
  }
  return (
    <>
      {app && <AppUnlockCard className={className} />}
      {state && <DeleteAccountCard initial={state} className={className} />}
    </>
  );
}
