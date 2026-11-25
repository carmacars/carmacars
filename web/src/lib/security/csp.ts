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
// Hotfix 3420 (Nov 23): Stripe.js now starts its frames on subdomains of js.stripe.com (Stripe's CSP guide), and Link's
// frames come from link.com: without them the card box stayed empty on Sign and pay.
const STRIPE_JS = 'https://js.stripe.com https://*.js.stripe.com', STRIPE_HOOKS = 'https://hooks.stripe.com', STRIPE_API = 'https://api.stripe.com';
const STRIPE_LINK = 'https://link.com https://*.link.com';
const R2_UPLOADS = 'https://*.r2.cloudflarestorage.com';
// r50: Helcim (the Canadian card processor since Stripe closed the account). HelcimPay.js loads from secure.helcim.app and
// opens its card modal in an iframe from the same host; the browser never calls api.helcim.com (our server does).
const HELCIM = 'https://secure.helcim.app';

export interface CspOptions {
  turnstile?: boolean;
  /** Extra origins images may come from (the vehicle photo bucket). */
  imgOrigins?: string[];
  /** Extra origins the browser may call (Supabase). */
  connectOrigins?: string[];
  /** Add upgrade-insecure-requests (on for https; off for the local http server). */
  upgrade?: boolean;
  /** Who may frame the page: 'none' unless the page is embeddable (the partner widget, 0147). */
  frameAncestors?: string;
  /** r44 (2790): calls in the browser on the staff and Admin portals (Twilio's Voice SDK, self-hosted): its signalling
   *  (wss), its call quality reports and its ring sounds. Public pages never get these origins. */
  voice?: boolean;
  /** r50 (5010): the company's media server for the calls in the site (LiveKit: its signalling wss and its API), on the
   *  staff, Admin and candidate call pages only (callPage). The audio and video are WebRTC, which the policy does not cover. */
  calls?: string[];
}

/** The pages with a call in the site (r50, 5010): the staff and Admin portals, and a candidate's interview call. */
export function callPage(path: string): boolean {
  return /^\/(staff|admin)(\/|$)/.test(path) || /^\/call\//.test(path);
}

/** The origins of the media server's URL (wss://meet.example.ca -> wss and https of that host); none when unset or not secure. */
export function mediaOrigins(url: string | undefined | null): string[] {
  const m = /^(wss|https):\/\/([a-z0-9.-]+(?::\d+)?)(\/|$)/i.exec(url ?? '');
  return m ? [`wss://${m[2]!.toLowerCase()}`, `https://${m[2]!.toLowerCase()}`] : [];
}

// Twilio's Voice SDK: signalling on wss://*.twilio.com (voice-js and the regional chunderw hosts), call insights on
// eventgw, the ringing and dial tones on sdk.twilio.com. The audio itself is WebRTC media, which the policy does not cover.
const TWILIO_VOICE_CONNECT = ['wss://*.twilio.com', 'https://eventgw.twilio.com', 'https://sdk.twilio.com'];
const TWILIO_VOICE_MEDIA = 'https://sdk.twilio.com';

/** The pages with the browser's phone (r44): the staff and Admin portals. */
export function voicePage(path: string): boolean {
  return /^\/(staff|admin)(\/|$)/.test(path);
}

/** The pages other sites may put in an iframe: the partner inventory widget only (migration 0147). */
export function embeddable(path: string): boolean {
  return /^\/partner-widget\/[0-9a-f-]{36}$/.test(path);
}

export function cspHeader(nonce: string, o: CspOptions = {}): string {
  const turnstile = o.turnstile ? ' https://challenges.cloudflare.com' : '';
  const img = ['\'self\'', 'data:', 'blob:', ...(o.imgOrigins ?? [])].join(' ');
  const connect = ['\'self\'', ...(o.connectOrigins ?? []), 'https://*.supabase.co', 'wss://*.supabase.co', STRIPE_API, STRIPE_LINK, HELCIM, R2_UPLOADS, ...(o.voice ? TWILIO_VOICE_CONNECT : []), ...(o.calls ?? [])].join(' ');
  return [
    `default-src 'self'`,
    // 'wasm-unsafe-eval': WebAssembly only (release 28: the VIN barcode reader, self-hosted zxing-wasm), never eval of strings
    `script-src 'self' 'nonce-${nonce}' 'wasm-unsafe-eval'${turnstile} ${STRIPE_JS} ${HELCIM}`,
    `style-src 'self' 'unsafe-inline'`,
    `img-src ${img} https:`,
    `font-src 'self'`,
    // the investor deck's narrated video, its poster and captions: short-lived signed links to Supabase Storage
    `media-src 'self' blob: ${['https://*.supabase.co', ...(o.connectOrigins ?? []), ...(o.voice ? [TWILIO_VOICE_MEDIA] : [])].join(' ')}`,
    `connect-src ${connect}${turnstile}`,
    `frame-src${turnstile} ${STRIPE_JS} ${STRIPE_HOOKS} ${STRIPE_LINK} ${HELCIM}`,
    `frame-ancestors ${o.frameAncestors ?? "'none'"}`,
    // phone alerts (migration 0300): the alerts service worker (/push-sw.js) and the web app manifest come from this
    // origin only. Both were already allowed (worker-src falls back to script-src, manifest-src to default-src); naming
    // them keeps a future script-src origin (Stripe, Turnstile) from ever running a worker here.
    `worker-src 'self'`,
    `manifest-src 'self'`,
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
    'Permissions-Policy': 'camera=(self), microphone=(self), geolocation=(self), payment=(self "https://js.stripe.com" "https://*.js.stripe.com" "https://secure.helcim.app"), usb=(), interest-cohort=()',
    'Cross-Origin-Opener-Policy': 'same-origin'
  };
}
