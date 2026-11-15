import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runPhoneJob, runPhoneTexts } from '@/server/phone';

// The phone line's job (migration 0085), from the Worker's five-minute cron tick when the database says something is
// due (public.server_jobs_due, "phone"): booking texts whose time came, and the AI one-liners of calls. r48: a body of
// {"only": "texts"} (the server's listen, the moment a text is queued) sends the texts and nothing else.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const body = (await req.json().catch(() => null)) as { only?: unknown } | null;
  return NextResponse.json(body?.only === 'texts' ? await runPhoneTexts() : await runPhoneJob());
}
