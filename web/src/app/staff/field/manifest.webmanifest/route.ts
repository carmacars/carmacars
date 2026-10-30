// The staff portal's web app manifest (06-field.md section 1; one portal since 0197): installs as "CarmaCars staff",
// opens the field jobs full screen, scoped to the staff portal.
export const dynamic = 'force-static';
export function GET() {
  return new Response(JSON.stringify({
    name: 'CarmaCars staff', short_name: 'CC staff', description: 'Your CarmaCars work: field jobs, handovers, returns and checklists.',
    id: '/staff/field', start_url: '/staff/field', scope: '/staff', display: 'standalone', orientation: 'portrait', background_color: '#ffffff', theme_color: '#000000',
    icons: [
      { src: '/staff/field/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/staff/field/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/staff/field/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }]
  }), { headers: { 'content-type': 'application/manifest+json', 'cache-control': 'public, max-age=3600' } });
}
