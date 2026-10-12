import 'server-only';
import { env } from '@/lib/env';

// Cloudflare Turnstile on every public form, checked on the server before anything is written.
// The fake adapter accepts only the token Cloudflare's test keys produce, so a form that forgets
// to send a token still fails locally.
export const TEST_TOKEN = 'XXXX.DUMMY.TOKEN.XXXX';

export async function verifyTurnstile(token: string | undefined | null, ip?: string | null): Promise<boolean> {
  if (!token) return false;
  const e = env();
  if (e.TURNSTILE_PROVIDER === 'fake') return token === TEST_TOKEN;
  const body = new URLSearchParams({ secret: e.TURNSTILE_SECRET_KEY, response: token });
  if (ip) body.set('remoteip', ip);
  try {
    const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body });
    const j = (await r.json()) as { success?: boolean };
    return j.success === true;
  } catch {
    return false;
  }
}
