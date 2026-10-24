import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runDuePartnerCrm } from '@/server/partner-crm';

// The partner CRM links (migration 0136), from the Worker's five-minute cron tick when the database says one is due
// (public.server_jobs_due, "crm": every 15 minutes, and soon after a change to a car, a rate, a photo or a booking).
// The jobs' bearer token only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runDuePartnerCrm());
}
