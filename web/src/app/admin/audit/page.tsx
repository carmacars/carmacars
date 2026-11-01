import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: the audit log is the Changes tab of Settings > Logs (?tab=access goes to Data access; a filter or search is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/logs', 'changes', await searchParams, { changes: 'changes', access: 'access' }));
}
