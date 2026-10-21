import { standInSvg } from '@/features/car/studio';

// The stand-in images of a real car with no photo yet (migration 0073): the sample cars' studio drawing for its body
// shape and colour with its model's name behind the car, e.g. /sample-photos/studio/sedan/black/lead/MALIBU.svg.
// The answer depends only on the address, so it is cached for a year by the browser and the CDN.
export const dynamic = 'force-static';
export const dynamicParams = true;
export async function generateStaticParams() { return []; }

type P = { params: Promise<{ shape: string; paint: string; shot: string; name: string }> };
export async function GET(_req: Request, { params }: P) {
  const { shape, paint, shot, name } = await params;
  const m = /^(.{1,60})\.svg$/.exec(decodeURIComponent(name));
  const svg = m ? standInSvg({ shape, paint, shot, name: m[1]! }) : null;
  if (!svg) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return new Response(svg, { headers: {
    'content-type': 'image/svg+xml; charset=utf-8', 'cache-control': 'public, max-age=31536000, immutable',
    'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'", 'x-content-type-options': 'nosniff'
  } });
}
