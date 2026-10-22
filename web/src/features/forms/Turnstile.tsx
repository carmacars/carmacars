'use client';
import Script from 'next/script';
import { publicEnv } from '@/lib/public-env';

// Cloudflare Turnstile, invisible unless Cloudflare asks for a challenge. It writes its token to a
// hidden input named cf-turnstile-response inside the form. The script loads only on pages with a
// form (docs/blueprint/14-seo.md: no third-party origin at load). Locally the fake mode supplies
// the token Cloudflare's test keys produce, and the server's fake verifier accepts only that.
export const FAKE_TOKEN = 'XXXX.DUMMY.TOKEN.XXXX';

export function Turnstile({ action }: { action: string }) {
  if (publicEnv.turnstileMode !== 'cloudflare') return <input type="hidden" name="cf-turnstile-response" value={FAKE_TOKEN} />;
  return (
    <>
      <Script src="https://challenges.cloudflare.com/turnstile/v0/api.js" strategy="afterInteractive" />
      <div className="cf-turnstile" data-sitekey={publicEnv.turnstileSiteKey} data-action={action} data-size="flexible" data-appearance="interaction-only" />
    </>
  );
}

type TurnstileApi = { reset: (el?: Element | string) => void; getResponse?: (el?: Element | string) => string | undefined };

/** A fresh token for this form, just before it is sent: a token is single use and lasts 5 minutes, so one taken at page
 *  load fails on a long form, or on a second try after an error. Resets the widget and waits for the new token (up to
 *  15 s). null: the check never answered (blocked by a content blocker or a privacy setting). */
export async function freshTurnstileToken(form: HTMLFormElement): Promise<string | null> {
  if (publicEnv.turnstileMode !== 'cloudflare') return FAKE_TOKEN;
  const input = () => form.querySelector<HTMLInputElement>('input[name="cf-turnstile-response"]');
  const box = form.querySelector('.cf-turnstile');
  const api = (window as unknown as { turnstile?: TurnstileApi }).turnstile;
  if (api && box) { try { api.reset(box); } catch { /* not rendered yet */ } }
  const until = Date.now() + 15_000;
  while (Date.now() < until) {
    const v = input()?.value;
    if (v) return v;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}
