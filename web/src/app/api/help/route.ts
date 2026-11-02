import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import type { GuideData } from '@/server/guides';
import { isGuidePortal } from '@/server/guides';

// "Stuck?" help (migration 0510) for the signed-in person's browser (StuckHelp.tsx):
//   GET  /api/help                    the settings (on, minutes, errors)
//   GET  /api/help?portal=va&slug=x   and one chapter of that portal's published guide, to show in the side panel
//   POST /api/help {portal, route, tab, trigger, action}   what happened (Admin sees the pages that trigger it most)
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return json({ error: 'Sign in first' }, 401);
  const url = new URL(req.url);
  const settings = await rpc('help_stuck_settings', {}, SR).catch(() => null);
  const portal = url.searchParams.get('portal') ?? '';
  const slug = url.searchParams.get('slug') ?? '';
  if (!portal || !slug) return json({ settings });
  if (!isGuidePortal(portal) || !/^[a-z0-9-]{1,80}$/.test(slug)) return json({ error: 'Unknown chapter' }, 400);
  const g = (await rpc('guide_read', { p_by: user.id, p_portal: portal }, SR).catch(() => null)) as unknown as GuideData | null;
  const s = g?.sections.find((x) => x.slug === slug);
  if (!s) return json({ settings, section: null });
  return json({ settings, section: { slug: s.slug, title: s.title, blurb: s.blurb, html: s.html } });
}

export async function POST(req: Request) {
  const user = await currentUser();
  if (!user || (await viewAs())) return new Response(null, { status: 204 });
  let b: Record<string, unknown> = {};
  try { b = (await req.json()) as Record<string, unknown>; } catch { return new Response(null, { status: 204 }); }
  const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : null);
  const p = { portal: str(b.portal, 20), route: str(b.route, 200)?.replace(/[^A-Za-z0-9/_[\].-]/g, '') ?? null, tab: str(b.tab, 60), trigger: str(b.trigger, 10), action: str(b.action, 10) };
  await rpc('help_stuck_log', { p_by: user.id, p }, SR).catch(() => undefined);
  return new Response(null, { status: 204 });
}
