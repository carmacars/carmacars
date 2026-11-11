import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runMeetJob } from '@/server/meet/google';

// Interview calls on Google Meet (migration 2303), from the Worker's five-minute tick while a call waits for its event
// (public.server_jobs_due, "meet").
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runMeetJob());
}
