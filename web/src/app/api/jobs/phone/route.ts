import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runPhoneJob } from '@/server/phone';

// The phone line's job (migration 0085), from the Worker's five-minute cron tick when the database says something is
// due (public.server_jobs_due, "phone"): booking texts whose time came, and the AI one-liners of calls.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runPhoneJob());
}
