import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { SignInState } from '@/features/portal/SignInSettings';
import type { Reach } from '@/features/phone/alerts';

/** The signed-in person's sign-in details for the profile pages (migration 0091, app.my_sign_in). */
export async function signInState(userId: string): Promise<SignInState | null> {
  return ((await rpc('server_my_sign_in', { p_user: userId }, { role: 'service_role' }).catch(() => null)) as unknown as SignInState | null);
}

/** Before accepting an offer, signing or paying (0091): {ok, reason: unconfirmed | email_needed}. */
export async function accountGate(userId: string, step: 'accept' | 'sign' | 'pay'): Promise<{ ok: boolean; reason?: 'unconfirmed' | 'email_needed'; by_phone?: boolean }> {
  return (await rpc('server_account_gate', { p_user: userId, p_step: step }, { role: 'service_role' })) as unknown as { ok: boolean; reason?: 'unconfirmed' | 'email_needed'; by_phone?: boolean };
}
export const GATE_MESSAGE = 'Confirm your account first: open the link we emailed you, or verify your phone number under Profile.';

/** How the signed-in person is reached (0096, app.my_notify_channel): their choice and what it means now. */
export async function notifyReach(userId: string): Promise<Reach | null> {
  return ((await rpc('server_my_notify_channel', { p_user: userId }, { role: 'service_role' }).catch(() => null)) as unknown as Reach | null);
}
