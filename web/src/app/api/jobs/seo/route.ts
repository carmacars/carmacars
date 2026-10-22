import { NextResponse } from 'next/server';
import { workerToken } from '@/server/listing-worker';
import { runIndexNowSweep, runSeoJobNow } from '@/server/seo-job';

// The search job's door (migration 0061). Called by the Worker's Cloudflare cron trigger (custom-worker.ts, every
// five minutes) with the listing worker's bearer token; any other caller gets 403. Answers what it did (counts and
// addresses), never the copy.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  // the next IndexNow batch of the vehicle pages (0097): one request of up to 10,000 addresses a run, sent even when the
  // copy job fails (0104: the sweep had never run)
  const sweep = () => runIndexNowSweep().catch((e) => ({ sent: 0, why: e instanceof Error ? e.message.slice(0, 120) : 'failed' }));
  try {
    const s = await runSeoJobNow({ limit: 2, deadlineMs: 25_000 });
    return NextResponse.json({ ok: true, ...s, errors: s.errors.slice(0, 5), indexnow_sweep: await sweep() });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed', indexnow_sweep: await sweep() }, { status: 500 });
  }
}
