import { rpc } from '@/lib/db/repo';

// A car's CarmaCars calendar as iCal (migration 0062), for Turo, Getaround and other platforms to import: busy times
// only ("Booked"), nothing about renters. The link is the car's private 64-character token (Cars > Calendar sync),
// rotatable. ?for=turo leaves out the trips imported from Turo itself (and so on), so nothing echoes back.
export const dynamic = 'force-dynamic';
const TOKEN = /^[0-9a-f]{64}$/;
const FOR = new Set(['turo', 'getaround', 'other', 'all']);

export async function GET(req: Request, ctx: { params: Promise<{ token: string }> }) {
  const token = (await ctx.params).token.replace(/\.ics$/i, '').toLowerCase();
  if (!TOKEN.test(token)) return new Response('Not found', { status: 404 });
  const f = new URL(req.url).searchParams.get('for') ?? '';
  const ics = (await rpc('calendar_export_ics', { p_token: token, p_for: FOR.has(f) ? f : '' }, { role: 'service_role' })) as unknown as string | null;
  if (!ics) return new Response('Not found', { status: 404, headers: { 'cache-control': 'no-store' } });
  return new Response(ics, {
    headers: {
      'content-type': 'text/calendar; charset=utf-8',
      'content-disposition': 'inline; filename="carmacars.ics"',
      'cache-control': 'private, max-age=300',
      'x-robots-tag': 'noindex, nofollow'
    }
  });
}
