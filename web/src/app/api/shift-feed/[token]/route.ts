import { rpc } from '@/lib/db/repo';

// r50 (5050): a person's private shift calendar (every field shift for an Admin or Fleet, a field staff member's own),
// as iCal for Google Calendar and other apps to subscribe to. The link is the feed's 64-character token, revocable and
// regenerable from the "Add shifts to Google Calendar" card; a revoked or unknown token answers 404.
export const dynamic = 'force-dynamic';
const TOKEN = /^[0-9a-f]{64}$/;

export async function GET(_req: Request, ctx: { params: Promise<{ token: string }> }) {
  const token = (await ctx.params).token.replace(/\.ics$/i, '').toLowerCase();
  const head = { 'x-robots-tag': 'noindex, nofollow', 'referrer-policy': 'no-referrer' };
  if (!TOKEN.test(token)) return new Response('Not found', { status: 404, headers: { ...head, 'cache-control': 'no-store' } });
  const ics = (await rpc('server_shift_feed', { p_token: token }, { role: 'service_role' }).catch(() => null)) as unknown as string | null;
  if (!ics) return new Response('Not found', { status: 404, headers: { ...head, 'cache-control': 'no-store' } });
  return new Response(ics, {
    headers: { ...head, 'content-type': 'text/calendar; charset=utf-8', 'content-disposition': 'inline; filename="carmacars-shifts.ics"', 'cache-control': 'no-store' }
  });
}
