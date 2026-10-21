import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import type { Bucket } from '@/integrations/storage';

// The retention purge (migration 0071), hourly from the Worker's cron (custom-worker.ts): the private files whose time
// has come (licence images and selfies 90 days after the rental, rental records after 7 years; never one on legal hold
// or under an open claim or dispute) are deleted from storage, then marked purged. A file already gone counts as done.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const due = ((await rpc('server_documents_due_for_purge', { p_limit: 200 }, SR)) ?? []) as unknown as Array<{ id: string; bucket: string; path: string }>;
  if (!due.length) return NextResponse.json({ ok: true, purged: 0 });
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  const done: string[] = [];
  let failed = 0;
  for (const d of due) {
    try { await s.remove(d.bucket as Bucket, d.path); done.push(d.id); } catch { failed++; }
  }
  const n = done.length ? Number(await rpc('server_mark_documents_purged', { p_ids: done }, SR)) : 0;
  return NextResponse.json({ ok: true, purged: n, failed });
}
