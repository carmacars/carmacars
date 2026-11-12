import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runGscSyncNow } from '@/server/gsc/google';

// The site's Search Console sync (migration 2640), from the five-minute tick when the database says the day's sync is due
// (public.server_jobs_due, "gsc": connected, on, and not done today). Answers counts only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runGscSyncNow());
}
