import { redirect } from 'next/navigation';
import { requireAdmin } from '@/server/admin/data';
import { historyHref, historyParams } from '@/features/visitors/history';

export const dynamic = 'force-dynamic';

// Today > Visitor history (migration 0118) is now the Visitors page's History (Release 26). Old links keep their
// filters and page; the gate is the same (Admins), checked before the move. A visit's own page stays at
// /admin/live/history/<id>.
export default async function VisitorHistory({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([requireAdmin('/admin/visitors?view=history'), searchParams]);
  const p = historyParams(sp);
  redirect(historyHref(p, p.cursor ?? null));
}
