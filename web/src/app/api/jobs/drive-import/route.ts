import { NextResponse } from 'next/server';
import { jobAuthorized } from '@/server/job-auth';
import { kickDriveImport, runDriveImportStep } from '@/server/drive-import';

// Import photos from a Google Drive link (migration 0760): one step of a run (some folders read, or the folders matched to
// cars, or up to three photos taken), called right after a run starts or is confirmed (src/server/drive-import.ts) and by the
// listing route on the Worker's five-minute tick, with the jobs' bearer token; any other caller gets 403. When more is left it
// starts the next step in its own request, so each stays inside the Worker's CPU and memory.
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  try {
    const r = await runDriveImportStep({ deadlineMs: 20_000 });
    if (r.more) kickDriveImport();
    return NextResponse.json({ ok: true, ...r });
  } catch (e) {
    console.error('drive import', e);
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
