import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { isGuidePortal } from '@/server/guides';

// The published content of a guide, for the PDF printer (web/scripts/guides-pdf.mjs, the guides-pdf workflow), with
// the jobs' bearer token. The HTML was rendered when the guide was published; nothing is rendered here.
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const portal = new URL(req.url).searchParams.get('portal') ?? '';
  if (!isGuidePortal(portal)) return new NextResponse('Unknown guide', { status: 404 });
  const [content, site] = await Promise.all([rpc('server_guide_print_content', { p_portal: portal }, { role: 'service_role' }), rpc('site_settings_public', {})]);
  const s = site as unknown as { public_email: string | null; phone_display: string | null; site_url: string };
  return NextResponse.json({ ...(content as unknown as Record<string, unknown>), contact: { email: s.public_email, phone: s.phone_display, site: s.site_url } }, { headers: { 'cache-control': 'no-store' } });
}
