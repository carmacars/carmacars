import { NextResponse } from 'next/server';
import { workerToken } from '@/server/listing-worker';
import { runStatementMail } from '@/server/statement-mail';

// The monthly statement emails (migration 0033): called by the Worker's cron trigger once an hour
// (custom-worker.ts) with the same bearer token as the listing worker; any other caller gets 403.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    return NextResponse.json({ ok: true, ...(await runStatementMail()) });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
