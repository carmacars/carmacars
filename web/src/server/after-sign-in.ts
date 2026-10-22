import 'server-only';
import { cookies } from 'next/headers';
import { auth } from '@/lib/auth';
import { rolesOf, VA_FN_COOKIE } from '@/server/door';
import { landingFor } from '@/server/portals';
import { VIEW_AS_COOKIE, VIEW_AS_UI_COOKIE } from '@/lib/security/view-as-guard';

/** After the password or the texted code: the second step when the person enrolled one (or must, as staff with the
 *  switch on), then the page asked for, or their portal (the "Choose a portal" page when they have several). */
export async function afterSignIn(userId: string, next: string | null): Promise<string> {
  const a = await auth();
  const roles = await rolesOf(userId);
  const home = next ?? landingFor(roles);
  const factors = (await a.mfaFactors().catch(() => [])).filter((f) => f.verified);
  if (factors.length) return `/two-step?next=${encodeURIComponent(home)}`;
  if (roles.staff && roles.two_step_required) return `/two-step/setup?next=${encodeURIComponent(home)}`;
  return home;
}

/** The cookies that belong to one session in a browser: a view-as and the assistant's chosen function. */
export async function clearSessionCookies(all: boolean) {
  try {
    const jar = await cookies();
    for (const n of [VIEW_AS_COOKIE, VIEW_AS_UI_COOKIE, ...(all ? [VA_FN_COOKIE] : [])]) if (jar.get(n)) jar.delete(n);
  } catch { /* read-only context */ }
}

/** The sign-in the sign-in page opens on, on this device (phone or email); readable by the page's script. */
export const SIGN_IN_PREF_COOKIE = 'cc-signin';
export async function rememberSignIn(method: 'phone' | 'email') {
  try { (await cookies()).set(SIGN_IN_PREF_COOKIE, method, { httpOnly: false, sameSite: 'lax', path: '/', maxAge: 365 * 86400 }); } catch { /* read-only context */ }
}
