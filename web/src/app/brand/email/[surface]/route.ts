import { getSettings, photoUrl } from '@/lib/site';

// The logo in every email (release 28; emails/src/layout.mjs and scripts/deploy/auth-templates.mjs link here):
// /brand/email/on-dark.png (white letters, the black header) and /brand/email/on-light.png (black letters, the light
// footer). It sends the logo uploaded in Admin > Settings > Site when one is a PNG or JPEG (email clients show no SVG),
// otherwise the brand kit's PNG (public/brand). A redirect, so an Admin's new logo reaches emails already sent.
export const dynamic = 'force-dynamic';

const DEFAULT = { 'on-dark.png': '/brand/carma-logo-white-1000w.png', 'on-light.png': '/brand/carma-logo-black-1000w.png' } as const;

export async function GET(req: Request, { params }: { params: Promise<{ surface: string }> }) {
  const { surface } = await params;
  if (!(surface in DEFAULT)) return new Response('Not found', { status: 404 });
  const s = await getSettings().catch(() => null);
  const uploaded = s ? (surface === 'on-dark.png' ? (s.logo.dark ?? s.logo.light) : s.logo.light) : null;
  const to = uploaded && /\.(png|jpe?g)$/i.test(uploaded) ? photoUrl(uploaded) : DEFAULT[surface as keyof typeof DEFAULT];
  return new Response(null, { status: 302, headers: { location: new URL(to, req.url).toString(), 'cache-control': 'public, max-age=3600' } });
}
