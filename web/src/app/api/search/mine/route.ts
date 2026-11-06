import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { sessionAal } from '@/server/door';

// A signed-in person's own records in the site search (release 28, B4; migration 0561): the database answers as that
// person, with the same rules as each table's row-level security, so no role finds another's rows. Never cached.
// Viewing as someone (Admin's View as) searches as them: a read.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function GET(req: Request) {
  const headers = { 'cache-control': 'private, no-store', 'x-robots-tag': 'noindex' };
  const q = (new URL(req.url).searchParams.get('q') ?? '').trim().slice(0, 80);
  const user = await currentUser().catch(() => null);
  if (!user) return NextResponse.json({ q, groups: [], signedIn: false }, { headers });
  if (q.length < 2) return NextResponse.json({ q, groups: [], signedIn: true }, { headers });
  try {
    const r = (await rpc('server_search_mine', { p_user: user.id, p_aal: (await sessionAal()) ?? '', p_q: q }, SR)) as unknown as { q: string; groups: unknown[] };
    return NextResponse.json({ ...r, signedIn: true }, { headers });
  } catch (e) {
    const two = e instanceof Error && /two-step/i.test(e.message);
    return NextResponse.json({ q, groups: [], signedIn: true, message: two ? 'Finish the two-step sign-in to search your records.' : 'Your records could not be searched just now.' }, { headers });
  }
}
