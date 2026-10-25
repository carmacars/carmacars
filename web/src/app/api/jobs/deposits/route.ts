import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runDepositGuard } from '@/server/deposit-guard';

// The deposit guard (migration 0155), from the Worker's five-minute cron tick when the database says it is due
// (public.server_jobs_due, "deposits": a card hold to capture before it lapses, a money step waiting for Stripe, or the
// day's balance follow-up). Never releases a deposit. The jobs' bearer token only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runDepositGuard());
}
