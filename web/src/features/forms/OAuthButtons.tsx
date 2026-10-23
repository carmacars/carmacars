'use client';
import Link from 'next/link';
import type { JSX } from 'react';
import { useSearchParams } from 'next/navigation';
import { OAUTH_PROVIDERS, oauthMessage, type OAuthProvider } from '@/lib/auth/oauth';

// Google's own "G" (Sign in with Google branding guidelines: the full-colour mark on a neutral button, unchanged).
function GoogleG() {
  return (
    <svg className="btn-oauth__logo" viewBox="0 0 48 48" width="18" height="18" aria-hidden="true" focusable="false">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
      <path fill="none" d="M0 0h48v48H0z" />
    </svg>
  );
}
function MicrosoftLogo() {
  return (
    <svg className="btn-oauth__logo" viewBox="0 0 21 21" width="18" height="18" aria-hidden="true" focusable="false">
      <path fill="#F25022" d="M1 1h9v9H1z" /><path fill="#7FBA00" d="M11 1h9v9h-9z" /><path fill="#00A4EF" d="M1 11h9v9H1z" /><path fill="#FFB900" d="M11 11h9v9h-9z" />
    </svg>
  );
}
function FacebookLogo() {
  return (
    <svg className="btn-oauth__logo" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="12" fill="#0866FF" />
      <path fill="#fff" d="M13.4 24v-8.4h2.8l.5-3.4h-3.3V10c0-1 .4-1.8 1.9-1.8h1.5V5.3c-.3 0-1.3-.2-2.5-.2-2.6 0-4.3 1.6-4.3 4.5v2.6H7.2v3.4H10V24z" />
    </svg>
  );
}
const LOGO: Partial<Record<OAuthProvider, () => JSX.Element>> = { google: GoogleG, microsoft: MicrosoftLogo, facebook: FacebookLogo };

/** "Continue with Google" (and the other providers switched on), then "or" above the email form. Plain links: the
 *  flow starts at /auth/oauth (src/app/auth/oauth/route.ts). */
export function OAuthButtons({ providers, intent, next, minAge }: { providers: OAuthProvider[]; intent: 'signin' | 'signup'; next?: string; minAge?: string }) {
  const sp = useSearchParams();
  const n = next ?? sp.get('next') ?? '';
  const msg = oauthMessage(sp.get('oauth'), sp.get('provider'));
  if (!providers.length && !msg) return null;
  const href = (p: OAuthProvider) => `/auth/oauth?${new URLSearchParams({ provider: p, intent, ...(n ? { next: n } : {}) })}`;
  return (
    <div className="oauth stack" data-testid="oauth">
      {msg && <p className="alert alert--error" role="alert" data-testid="oauth-error"><span>{msg}</span></p>}
      {providers.map((p) => {
        const Logo = LOGO[p];
        return (
          // a full page load, never a client-side route change: the browser leaves for the provider
          <a key={p} className="btn-oauth" href={href(p)} data-testid={`oauth-${p}`} rel="nofollow">
            {Logo && <Logo />}<span>Continue with {OAUTH_PROVIDERS[p].label}</span>
          </a>
        );
      })}
      {providers.length > 0 && <p className="small muted oauth__terms">By continuing with {providers.length === 1 ? OAUTH_PROVIDERS[providers[0]!].label : 'a provider'}, you confirm you are {minAge ?? '21'} or older and agree to the <Link className="link" href="/terms">Terms of use</Link> and <Link className="link" href="/privacy">Privacy policy</Link>.</p>}
      {providers.length > 0 && <p className="oauth__or" aria-hidden="true"><span>or</span></p>}
    </div>
  );
}
