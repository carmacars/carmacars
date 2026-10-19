import { rpc } from '@/lib/db/repo';

// The site's health answer for the site check (migration 0062): the Worker runs and reaches the database. One small
// database call; never cached. {"ok": true} or 503.
export const dynamic = 'force-dynamic';

export async function GET() {
  const headers = { 'cache-control': 'no-store', 'content-type': 'application/json' };
  try {
    const r = (await rpc('health_ping', {} as never, { role: 'service_role' })) as unknown as { ok: boolean; at: string };
    return new Response(JSON.stringify({ ok: r?.ok === true, at: r?.at ?? null }), { status: r?.ok ? 200 : 503, headers });
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'database' }), { status: 503, headers });
  }
}
