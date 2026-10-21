import { NextResponse } from 'next/server';
import { workerToken } from '@/server/listing-worker';
import { kickPdfJobs, runPdfJobs } from '@/server/pdf-jobs';

// Signed copies (migration 0077): called right after a signing (src/server/pdf-jobs.ts) and by the Worker's cron,
// with the jobs' bearer token; any other caller gets 403. Two renders per request at most; when more are waiting it
// starts the next request, so each one stays well inside the Worker's CPU and memory.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    const r = await runPdfJobs({ maxJobs: 2, deadlineMs: 15_000 });
    if (r.more && r.done > 0) kickPdfJobs();
    return NextResponse.json({ ok: true, ...r });
  } catch (e) {
    console.error('pdf jobs', e);
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
