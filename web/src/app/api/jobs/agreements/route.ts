import { NextResponse } from 'next/server';
import { workerToken } from '@/server/listing-worker';
import { runAgreementJobs, runPeriodJobs } from '@/server/agreement-auto';

// The rental agreements confirmed bookings are missing (migration 0132): called by the Worker's cron with the jobs' bearer
// token; any other caller gets 403. Three agreements per request at most (each is a PDF render).
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    const missing = await runAgreementJobs(3);
    // and the next period of each long rental, lead days ahead (0145)
    const periods = await runPeriodJobs(2);
    return NextResponse.json({ ok: true, ...missing, periods });
  } catch (e) {
    console.error('agreement jobs', e);
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
