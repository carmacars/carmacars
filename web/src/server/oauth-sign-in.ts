import 'server-only';
import { auth } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import { finishOAuth, type FinishDeps, type FinishResult, type OAuthFlow } from '@/lib/auth/oauth';
import { afterSignIn, clearSessionCookies } from '@/server/after-sign-in';
import { captureDone } from '@/server/capture';
import { requestMeta } from '@/server/request';

const SR = { role: 'service_role' as const };

/** The provider's code at /auth/callback: the sign-in finished with the site's own pieces (src/lib/auth/oauth.ts). */
export async function finishProviderSignIn(code: string, flow: OAuthFlow): Promise<FinishResult> {
  const a = await auth();
  const meta = await requestMeta();
  const deps: FinishDeps = {
    exchange: (c, state) => a.oauthExchange(c, state),
    signOut: () => a.signOut(),
    registerAccount: async (id, email, name) =>
      (await rpc('register_account', { p_user: id, p_email: email, p_full_name: name }, { ...SR, requestId: meta.requestId })) as unknown as { ok: boolean; error?: string; created?: boolean },
    userByEmail: async (email) => (await rpc('server_user_by_email', { p_email: email }, SR)) as unknown as string | null,
    relinkToRecord: (freshId, recordId, email, name) => a.relinkToRecord(freshId, recordId, email, name),
    emailVerified: async (id, email) => { await rpc('server_account_email_verified', { p_user: id, p_email: email }, SR); },
    clearSessionCookies: () => clearSessionCookies(false),
    signUpDone: () => captureDone('signup'),
    afterSignIn
  };
  return finishOAuth(deps, code, flow);
}
