import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { signInPaused } from '@/features/auth/sign-in-pause';

// Password sign-in by address (r48 security audit, migration 3400): the website's form and the app's sign-in each count
// one try against the address before the password is checked. The address comes from src/server/request.ts (in
// production never empty: a missing one is one shared address). Like the pause by email, a database that does not
// answer lets the sign-in through. The local stack and its tests sign in from one machine all day, so it is off there.
export async function signInIpPaused(ip: string | null): Promise<boolean> {
  if (env().APP_ENV === 'local') return false;
  const a = await rpc('server_sign_in_ip_allowed', { p_ip: ip ?? '' }, { role: 'service_role' }).catch(() => null);
  return signInPaused(a);
}
