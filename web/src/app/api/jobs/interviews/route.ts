import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runInterviewJob } from '@/server/interviews';

// The AI interviews' job (migration 0380), from the Worker's five-minute tick when the database says something waits
// (public.server_jobs_due, "interviews"): transcripts the answer page could not make, the AI's scores of a finished
// interview, and the audio of removed applications deleted from storage.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runInterviewJob());
}
