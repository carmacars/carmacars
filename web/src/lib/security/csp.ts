// Security headers and the content security policy, shared by the Worker entry
// (custom-worker.ts) and the local production server (scripts/serve.mjs).
// Script files load only from this origin (and Turnstile's), and an inline script runs only with
// the per-response nonce. No inline script runs without the nonce.

export function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

// Stripe's Payment Element (its script and its card frame) and browser uploads straight to R2.
const STRIPE_JS = 'https://js.stripe.com', STRIPE_HOOKS = 'https://hooks.stripe.com', STRIPE_API = 'https://api.stripe.com';
const R2_UPLOADS = 'https://*.r2.cloudflarestorage.com';

export interface CspOptions {
  turnstile?: boolean;
  /** Extra origins images may come from (the vehicle photo bucket). */
  imgOrigins?: string[];
  /** Extra origins the browser may call (Supabase). */
  connectOrigins?: string[];
  /** Add upgrade-insecure-requests (on for https; off for the local http server). */
  upgrade?: boolean;
}

export function cspHeader(nonce: string, o: CspOptions = {}): string {
  const turnstile = o.turnstile ? ' https://challenges.cloudflare.com' : '';
  const img = ['\'self\'', 'data:', 'blob:', ...(o.imgOrigins ?? [])].join(' ');
  const connect = ['\'self\'', ...(o.connectOrigins ?? []), 'https://*.supabase.co', 'wss://*.supabase.co', STRIPE_API, R2_UPLOADS].join(' ');
  return [
    `default-src 'self'`,
    `script-src 'self' 'nonce-${nonce}'${turnstile} ${STRIPE_JS}`,
    `style-src 'self' 'unsafe-inline'`,
    `img-src ${img} https:`,
    `font-src 'self'`,
    // the investor deck's narrated video, its poster and captions: short-lived signed links to Supabase Storage
    `media-src 'self' blob: ${['https://*.supabase.co', ...(o.connectOrigins ?? [])].join(' ')}`,
    `connect-src ${connect}${turnstile}`,
    `frame-src${turnstile} ${STRIPE_JS} ${STRIPE_HOOKS}`,
    `frame-ancestors 'none'`,
    `form-action 'self'`,
    `base-uri 'none'`,
    `object-src 'none'`,
    ...(o.upgrade === false ? [] : ['upgrade-insecure-requests'])
  ].join('; ');
}

export function securityHeaders(): Record<string, string> {
  return {
    'Strict-Transport-Security': 'max-age=63072000; includeSubDomains; preload',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Permissions-Policy': 'camera=(self), microphone=(), geolocation=(), payment=(self), usb=(), interest-cohort=()',
    'Cross-Origin-Opener-Policy': 'same-origin'
  };
}
