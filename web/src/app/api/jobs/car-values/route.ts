import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { runCarValues } from '@/server/car-values';

// The value job (migration 1202): the AI estimate of cars with no Black Book value, from the Worker's cron tick when
// public.server_jobs_due says "car_values". The jobs' bearer token only.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json(await runCarValues());
}
