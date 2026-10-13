// The field portal's web app manifest (06-field.md section 1): installs as "CarmaCars field", opens /field
// full screen, scoped to the field portal.
export const dynamic = 'force-static';
export function GET() {
  return new Response(JSON.stringify({
    name: 'CarmaCars field', short_name: 'CC field', description: 'Your CarmaCars field jobs: handovers, returns and checklists.',
    id: '/field', start_url: '/field', scope: '/field', display: 'standalone', orientation: 'portrait', background_color: '#ffffff', theme_color: '#000000',
    icons: [
      { src: '/field/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/field/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/field/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }]
  }), { headers: { 'content-type': 'application/manifest+json', 'cache-control': 'public, max-age=3600' } });
}
