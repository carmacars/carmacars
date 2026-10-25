import { NextResponse } from 'next/server';
import { workerToken } from '@/server/listing-worker';
import { runAgreementJobs, runPeriodJobs } from '@/server/agreement-auto';

// The agreements' background work (migrations 0132 and 0154, server/agreement-auto runAgreementJobs): the agreements
// confirmed bookings are missing, then new versions, check-out and check-in copies, signed copies and dispute packs.
// Called by the Worker's cron with the jobs' bearer token; any other caller gets 403. Three PDF renders per request at most.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    const jobs = await runAgreementJobs({ max: 3 });
    // and the next period of each long rental, lead days ahead (0148)
    const periods = await runPeriodJobs(2);
    return NextResponse.json({ ok: true, ...jobs, periods });
  } catch (e) {
    console.error('agreement jobs', e);
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
