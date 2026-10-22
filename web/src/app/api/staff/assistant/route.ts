import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { realUser } from '@/server/portal/data';
import { rolesOf, sessionAal } from '@/server/door';
import { viewAs } from '@/server/view-as';
import { decide, runAssistant } from '@/server/assistant';
import type { Portal } from '@/features/assistant/tools';
import type { Turn } from '@/features/assistant/agent';

// The staff assistant (migration 0080): a question, or Confirm or Cancel on a card. The signed-in person only, in a
// portal of theirs; nothing while an Admin views as someone. The database checks every read and change again.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };
const msg = (e: unknown) => (e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 300) : 'Something went wrong');

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ error: 'Not permitted' }, { status: 403, headers: H });
  const user = await realUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  if (await viewAs()) return NextResponse.json({ out: [{ type: 'text', text: 'The assistant is off while you view as someone. Exit view as to use it.' }] }, { headers: H });
  const b = (await req.json().catch(() => null)) as { portal?: string; text?: string; history?: Turn[]; confirm?: string; cancel?: string } | null;
  const portal = b?.portal as Portal;
  if (!b || !['admin', 'va', 'field'].includes(portal)) return NextResponse.json({ error: 'Unknown portal' }, { status: 400, headers: H });
  const roles = await rolesOf(user.id);
  if ((portal === 'admin' && !roles.admin) || (portal === 'va' && !roles.va) || (portal === 'field' && !roles.field)) return NextResponse.json({ error: 'Not your portal' }, { status: 403, headers: H });
  const aal = await sessionAal();
  if (roles.two_step_required && aal !== 'aal2') return NextResponse.json({ error: 'Finish two-step sign-in first' }, { status: 403, headers: H });
  const fn = portal === 'va' ? roles.va : null;
  try {
    if (b.confirm || b.cancel) {
      const r = await decide({ userId: user.id, aal, portal, fn, id: String(b.confirm ?? b.cancel), confirm: !!b.confirm });
      if (r.ok && b.confirm) revalidatePath(`/${portal}`, 'layout');
      return NextResponse.json(r, { headers: H });
    }
    const text = typeof b.text === 'string' ? b.text.slice(0, 1000) : '';
    const history = Array.isArray(b.history) ? b.history.filter((t) => t && (t.role === 'user' || t.role === 'assistant') && typeof t.text === 'string').slice(-6) : [];
    const out = await runAssistant({ userId: user.id, aal, portal, fn, name: roles.name, text, history });
    return NextResponse.json({ out }, { headers: H });
  } catch (e) {
    return NextResponse.json({ out: [{ type: 'text', text: `The assistant could not do that: ${msg(e)}` }] }, { headers: H });
  }
}
