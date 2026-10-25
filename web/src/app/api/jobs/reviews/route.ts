import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runReviewsSync } from '@/server/reviews/google';

// The Google reviews sync (migration 0146), from the Worker's five-minute cron tick when the database says it is due
// (public.server_jobs_due, "reviews": connected and not synced for 6 hours).
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runReviewsSync());
}
