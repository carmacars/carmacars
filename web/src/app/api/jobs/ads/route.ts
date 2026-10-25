import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runAdsJob } from '@/server/ads';

// The ads job (migration 0167), from the Worker's five-minute cron tick when public.server_jobs_due says "ads": the posted
// ads checked against the rates, the week's drafts written, and the approved posts published while Meta publishing is on.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runAdsJob());
}
