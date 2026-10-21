import { NextResponse } from 'next/server';
import { runListingWorkerNow, workerToken } from '@/server/listing-worker';
import { runCarDetailsNow } from '@/server/car-details';

// The listing worker's door (docs/blueprint/09-listing-pipeline.md section 5.1). Called by the Worker's
// Cloudflare cron trigger (custom-worker.ts, every five minutes) with the bearer token derived from
// LINK_SIGNING_KEY; any other caller gets 403. Runs due jobs for up to about 25 seconds and answers
// what it did (no content of the jobs).
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    const s = await runListingWorkerNow({ maxJobs: 16, deadlineMs: 25_000 });
    // then the car details that come later (0079): a VIN decoded again, the colour from a cover photo
    const c = await runCarDetailsNow({ vins: 3, colours: 2 }).catch((e) => ({ decoded: 0, filled: 0, colours: 0, errors: [String(e).slice(0, 200)] }));
    return NextResponse.json({ ok: true, claimed: s.claimed, succeeded: s.succeeded, failed: s.failed, held: s.held, due: s.due, errors: [...s.errors, ...c.errors].slice(0, 5),
      details: { decoded: c.decoded, filled: c.filled, colours: c.colours } });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
