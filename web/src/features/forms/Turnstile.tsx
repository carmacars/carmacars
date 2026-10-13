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
      <Script src="https://challenges.cloudflare.com/turnstile/v0/api.js" strategy="lazyOnload" />
      <div className="cf-turnstile" data-sitekey={publicEnv.turnstileSiteKey} data-action={action} data-size="flexible" data-appearance="interaction-only" />
    </>
  );
}
