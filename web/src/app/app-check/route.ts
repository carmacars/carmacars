import { publicEnv } from '@/lib/public-env';

// The bot check for the native app (release 48, apps/carmacars-native). The app opens this small page in a sheet when a
// signed-out phone asks for a sign-in code by text, or sends a request to book: the two things the website guards with
// Cloudflare Turnstile. The page runs the same Turnstile widget with the same site key and hands the token to the app
// (ReactNativeWebView.postMessage); the app sends it with its request and the server verifies it exactly as it does for
// the website's forms (src/integrations/turnstile). Nothing else is on the page, and nothing is read from it.
// The server entry adds the nonce to the scripts and the security headers, as on every HTML response.
export const dynamic = 'force-dynamic';

const FAKE_TOKEN = 'XXXX.DUMMY.TOKEN.XXXX';
const esc = (s: string) => s.replace(/[^A-Za-z0-9_.-]/g, '');

export function GET() {
  const mode = publicEnv.turnstileMode;
  const send = `function send(t){try{window.ReactNativeWebView.postMessage(JSON.stringify({type:'turnstile',token:t}))}catch(e){}}`;
  const script = mode === 'cloudflare'
    ? `${send}window.onTurnstile=function(){turnstile.render('#box',{sitekey:'${esc(publicEnv.turnstileSiteKey)}',action:'app',size:'flexible',retry:'auto','refresh-expired':'auto',callback:send})};`
    : `${send}send('${mode === 'fake' ? FAKE_TOKEN : ''}');`;
  const html = `<!doctype html><html lang="en-CA"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>CarmaCars security check</title>
<style>html,body{margin:0;background:#fff;font:16px -apple-system,system-ui,sans-serif;color:#111}#box{display:flex;justify-content:center;padding:8px}</style></head>
<body><div id="box" role="status" aria-label="Security check"></div><script>${script}</script>
${mode === 'cloudflare' ? '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=onTurnstile" async defer></script>' : ''}</body></html>`;
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex, nofollow' } });
}
