import { handleTrackerIngest } from '@/server/tracker';

// The tracker ingest (migration 0400, docs/tracker-ingest.md): signed batches of positions in the generic JSON, from the
// GT06/JT808 relay on the server, a vendor's HTTP push (?format=) or the simulator. 401 without a good signature, 503
// until Admin makes the ingest key; a failure is 500 so the sender retries (a batch sent twice changes nothing).
export const dynamic = 'force-dynamic';

export async function POST(req: Request): Promise<Response> {
  const len = Number(req.headers.get('content-length') ?? 0);
  if (len > 512_000) return Response.json({ error: 'too large' }, { status: 413 });
  const raw = await req.text();
  try {
    const r = await handleTrackerIngest(raw, (n) => req.headers.get(n), new URL(req.url).searchParams.get('format') ?? 'generic');
    return Response.json(r.body, { status: r.status });
  } catch {
    return Response.json({ error: 'processing failed' }, { status: 500 });
  }
}
