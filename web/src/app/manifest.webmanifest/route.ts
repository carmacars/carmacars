// The site's web app manifest (migration 0300): "Add to Home Screen" installs CarmaCars full screen with the brand icon.
// It opens /app, which sends a signed-in person to their portal and anyone else to the home page. The staff portal's
// field pages keep their own manifest (staff/field/manifest.webmanifest). No offline pages: the only service worker
// (public/push-sw.js) shows alerts and caches nothing.
export const dynamic = 'force-static';

const MANIFEST = {
  name: 'CarmaCars', short_name: 'CarmaCars', description: 'Rent a car in Toronto, and your CarmaCars account: trips, bookings, payouts and alerts.',
  id: '/app', start_url: '/app', scope: '/', display: 'standalone', orientation: 'portrait', background_color: '#000000', theme_color: '#000000',
  lang: 'en-CA', dir: 'ltr', categories: ['travel', 'business'],
  icons: [
    { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
    { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
    { src: '/icons/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
  ]
} as const;

export function GET() {
  return new Response(JSON.stringify(MANIFEST), { headers: { 'content-type': 'application/manifest+json', 'cache-control': 'public, max-age=3600' } });
}
