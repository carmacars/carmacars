import 'server-only';
import { cookies } from 'next/headers';
import { env } from '@/lib/env';

/** The address last used on this device to ask for a link: the "link expired" page offers it again. */
export const LAST_EMAIL_COOKIE = 'cc-last-email';

export async function rememberEmail(email: string): Promise<void> {
  try {
    (await cookies()).set(LAST_EMAIL_COOKIE, email.trim().toLowerCase(), { httpOnly: true, sameSite: 'lax', path: '/', maxAge: 7 * 86400, secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:') });
  } catch { /* read-only context */ }
}

export async function lastEmail(): Promise<string | null> {
  try { return (await cookies()).get(LAST_EMAIL_COOKIE)?.value ?? null; } catch { return null; }
}

export const siteBase = () => env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');

/** Where a password link lands: the callback (Supabase; the email template links there with the token hash) or the
 *  page itself (the local stand-in adds the token). The page then sends the person to their portal. */
export function passwordLinkTarget(): string {
  return env().DATA_BACKEND === 'local' ? `${siteBase()}/update-password` : `${siteBase()}/auth/callback?next=/update-password`;
}
