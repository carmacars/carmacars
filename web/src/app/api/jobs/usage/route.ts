import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { jobAuthorized } from '@/server/job-auth';
import { cloudflareUsage } from '@/features/usage/cloudflare';

// The usage guard (migration 0080), hourly from the Worker's cron (custom-worker.ts): Cloudflare's figures when the
// Worker has a read-only analytics token (CLOUDFLARE_ANALYTICS_TOKEN and CLOUDFLARE_ACCOUNT_ID; without them the usage
// workflow reports them from GitHub every hour), then the database's refresh: what it measures itself, each service's
// state, the 80% and 100% alerts and their emails. pg_cron runs the same refresh at minute 11 as well.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const token = process.env.CLOUDFLARE_ANALYTICS_TOKEN, account = process.env.CLOUDFLARE_ACCOUNT_ID;
  let cloudflare: Record<string, unknown> = { skipped: 'no CLOUDFLARE_ANALYTICS_TOKEN in the Worker: the usage workflow reports the Cloudflare figures' };
  if (token && account) {
    try {
      // today and yesterday only: the workflow fills the rest of the month
      const now = new Date();
      const days = [new Date(now.getTime() - 24 * 3600_000), now].map((d) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d));
      const u = await cloudflareUsage({ token, account, now, days: [...new Set(days)] });
      if (u.days.length) await rpc('server_usage_record', { p: { source: 'cloudflare', days: u.days } as unknown as Json }, SR);
      cloudflare = { days: u.days.length, unavailable: u.unavailable };
    } catch (e) { cloudflare = { error: e instanceof Error ? e.message.slice(0, 200) : 'failed' }; }
  }
  const refresh = await rpc('server_usage_refresh', {}, SR);
  return NextResponse.json({ ok: true, cloudflare, refresh });
}
