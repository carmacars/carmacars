import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: the email log is the Emails tab of Settings > Logs (?tab=suppressions goes to Blocked addresses; a filter or search is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/logs', 'emails', await searchParams, { outbox: 'emails', suppressions: 'blocked' }));
}
