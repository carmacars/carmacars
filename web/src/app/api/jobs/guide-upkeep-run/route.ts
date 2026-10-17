import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';

// The automatic guide upkeep runs (migration 0055), with the jobs' bearer token (the guides workflow):
//   GET   the commit of the last run that finished, so a deploy that changed nothing in web/src or docs/guides skips quickly
//   POST  {run, sha, status, images, sections_rewritten, sections_flagged, pdfs, result}: what a run did
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function GET(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  return NextResponse.json({ ok: true, sha: await rpc('server_guide_upkeep_last_sha', {}, SR) });
}

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const p = await req.json().catch(() => null);
  if (!p || typeof p !== 'object' || !('run' in p)) return new NextResponse('run is needed', { status: 400 });
  return NextResponse.json({ ok: true, run: await rpc('server_guide_upkeep_run', { p }, SR) });
}
