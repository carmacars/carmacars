import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runPushJob } from '@/server/push';

// Phone and browser alerts (migration 0300), from the Worker's five-minute cron tick when the VAPID keys are set and the
// database says an alert is due (public.server_push_waiting): up to 200 alerts a run, encrypted and sent to each
// device's push service; 404 and 410 answers delete the subscription.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runPushJob(200));
}
