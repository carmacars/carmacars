'use client';
import { useEffect, useRef } from 'react';
import Script from 'next/script';
import { publicEnv } from '@/lib/public-env';

// Cloudflare Turnstile, invisible unless Cloudflare asks for a challenge. It writes its token to a
// hidden input named cf-turnstile-response inside the form. The script loads only on pages with a
// form (docs/blueprint/14-seo.md: no third-party origin at load). Locally the fake mode supplies
// the token Cloudflare's test keys produce, and the server's fake verifier accepts only that.
//
// Rendered explicitly when the box mounts: Cloudflare's automatic rendering only finds boxes already in the page when
// its script loads, so a box on a later step of a wizard (the owner application's last step, the request's last step)
// was never rendered and never gave a token ("security check did not load", Oct 21).
export const FAKE_TOKEN = 'XXXX.DUMMY.TOKEN.XXXX';

type RenderApi = { render: (el: Element, o: Record<string, unknown>) => string | undefined; remove?: (id: string) => void };

function renderBox(box: HTMLElement | null, action: string): string | undefined {
  const api = (window as unknown as { turnstile?: RenderApi }).turnstile;
  if (!api || !box || box.dataset.rendered === '1') return undefined;
  box.dataset.rendered = '1';
  try {
    return api.render(box, { sitekey: publicEnv.turnstileSiteKey, action, size: 'flexible', appearance: 'interaction-only' });
  } catch { box.dataset.rendered = ''; return undefined; }
}

export function Turnstile({ action }: { action: string }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (publicEnv.turnstileMode !== 'cloudflare') return;
    let id: string | undefined;
    const el = box.current;
    const tryRender = () => { if (!id) id = renderBox(el, action); return !!id || el?.dataset.rendered === '1'; };
    if (tryRender()) return () => { const api = (window as unknown as { turnstile?: RenderApi }).turnstile; if (id) api?.remove?.(id); };
    // the script is still loading: render as soon as it is there
    const t = setInterval(() => { if (tryRender()) clearInterval(t); }, 200);
    return () => { clearInterval(t); const api = (window as unknown as { turnstile?: RenderApi }).turnstile; if (id) api?.remove?.(id); };
  }, [action]);
  if (publicEnv.turnstileMode !== 'cloudflare') return <input type="hidden" name="cf-turnstile-response" value={FAKE_TOKEN} />;
  return (
    <>
      <Script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" strategy="afterInteractive" />
      <div ref={box} className="cf-turnstile" data-action={action} />
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
  if (box instanceof HTMLElement && box.dataset.rendered !== '1') renderBox(box, box.dataset.action ?? 'form');
  else if (api && box) { try { api.reset(box); } catch { /* not rendered yet */ } }
  const until = Date.now() + 15_000;
  while (Date.now() < until) {
    const v = input()?.value;
    if (v) return v;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}
