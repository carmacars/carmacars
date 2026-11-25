import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';

// Guide me (migration 3950) for the signed-in staff member's browser (features/guide-me/GuideMe.tsx):
//   GET  /api/guide-me                                  { on, run }: the preference and the run to resume
//   POST /api/guide-me {op: 'pref', on}                 keep Guide me on (or off)
//   POST /api/guide-me {op: 'start', flow, portal, total, step}         a run begins: { id }
//   POST /api/guide-me {op: 'step' | 'end', run, index, step, skipped, status}   where it stands, how it ended
// An Admin viewing the portal as someone writes nothing.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });
const id = (v: unknown, n = 60) => (typeof v === 'string' && /^[a-z0-9-]+$/.test(v) ? v.slice(0, n) : null);

export async function GET() {
  const user = await currentUser();
  if (!user) return json({ error: 'Sign in first' }, 401);
  const s = await rpc('guide_me_state', { p_by: user.id }, SR).catch(() => null);
  return json(s ?? { on: false, run: null });
}

export async function POST(req: Request) {
  const user = await currentUser();
  if (!user) return json({ error: 'Sign in first' }, 401);
  if (await viewAs()) return json({ ok: false, reason: 'view_as' });
  let b: Record<string, unknown> = {};
  try { b = (await req.json()) as Record<string, unknown>; } catch { return json({ error: 'Not JSON' }, 400); }
  const op = typeof b.op === 'string' && ['pref', 'start', 'step', 'end'].includes(b.op) ? b.op : null;
  if (!op) return json({ error: 'Unknown operation' }, 400);
  const run = typeof b.run === 'string' && /^[0-9a-f-]{36}$/i.test(b.run) ? b.run : null;
  const p = { op, on: b.on === true, flow: id(b.flow), portal: id(b.portal, 10), total: Number.isInteger(b.total) ? b.total : null, run,
    index: Number.isInteger(b.index) ? b.index : null, step: id(b.step), status: b.status === 'completed' || b.status === 'exited' ? b.status : null,
    skipped: Array.isArray(b.skipped) ? b.skipped.map((x) => id(x)).filter(Boolean).slice(0, 60) : [] };
  const r = await rpc('guide_me_do', { p_by: user.id, p }, SR).catch(() => null);
  return r ? json(r) : json({ ok: false }, 400);
}
