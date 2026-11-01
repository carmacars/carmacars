import { redirect } from 'next/navigation';
import { requireAdmin } from '@/server/admin/data';

export const dynamic = 'force-dynamic';

// Today > Live visitors (migration 0060) is now the Visitors page's Live now (Release 26). Old links and bookmarks land
// there; the gate is the same (Admins), checked before the move.
export default async function Live() {
  await requireAdmin('/admin/visitors');
  redirect('/admin/visitors');
}
