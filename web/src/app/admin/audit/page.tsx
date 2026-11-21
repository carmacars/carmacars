import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: the audit log is the Changes tab of Settings > Logs (?tab=access goes to Data access; a filter or search is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/audit']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
