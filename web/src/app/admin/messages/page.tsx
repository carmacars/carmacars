import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: the email log is the Emails tab of Settings > Logs (?tab=suppressions goes to Blocked addresses; a filter or search is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/messages']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
