import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { jobAuthorized, turoGmailAuthorized } from '@/server/job-auth';
import { bounceWords, readBounce } from '@/features/email-bounces/ndr';

// R51 (5307, REQ-136): bounce emails (NDRs and delivery status reports) from the mailbox our emails are sent from, posted as
// raw MIME by the Apps Script in rent@'s Gmail (scripts/turo-gmail.gs, its token) or by the Worker (the jobs' token).
// Only the failed address, the status, the reason and our reference go to the database (app.server_email_bounce, which
// acts only on an email we sent to that address). The message itself is never stored.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function POST(req: Request) {
  if (!(await jobAuthorized(req)) && !(await turoGmailAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const raw = await req.text();
  if (!raw || raw.length > 1_000_000) return NextResponse.json({ ok: false, error: 'empty or too large' }, { status: 413 });
  const found = readBounce(raw);
  const results: unknown[] = [];
  for (const b of found.slice(0, 10)) {
    results.push(await rpc('server_email_bounce', { p: { to: b.to, status: b.status, ref: b.ref, source: 'ndr',
      reason: [bounceWords(b), b.reason].filter(Boolean).join(' ').slice(0, 300) } as unknown as Json }, SR).catch(() => ({ matched: false, why: 'not recorded' })));
  }
  return NextResponse.json({ ok: true, bounces: found.length, results });
}
