import { rpc } from '@/lib/db/repo';
import { SCHEMA_HEADER, SCHEMA_MARKER } from '@/lib/schema-marker';

// The site's health answer for the site check (migrations 0062, 0063): the Worker runs and reaches the database. One
// small database call; never cached. {"ok": true, "schema": <this website's>, "db_schema": <the database's>} or 503.
export const dynamic = 'force-dynamic';

export async function GET() {
  const headers = { 'cache-control': 'no-store', 'content-type': 'application/json', [SCHEMA_HEADER]: SCHEMA_MARKER };
  try {
    const r = (await rpc('health_ping', {} as never, { role: 'service_role' })) as unknown as { ok: boolean; at: string; schema?: string };
    return new Response(JSON.stringify({ ok: r?.ok === true, at: r?.at ?? null, schema: SCHEMA_MARKER, db_schema: r?.schema ?? null }), { status: r?.ok ? 200 : 503, headers });
  } catch {
    return new Response(JSON.stringify({ ok: false, error: 'database', schema: SCHEMA_MARKER }), { status: 503, headers });
  }
}
