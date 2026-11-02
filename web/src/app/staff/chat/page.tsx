import { redirect } from 'next/navigation';
import { vaPage } from '@/server/va';
import { chatMovedTo } from '@/features/visitors/tabs';

export const dynamic = 'force-dynamic';

// Live chat (migration 0060) and Texts and calls (0085) are the staff Visitors page's Chat tab since the r27
// consolidation. Old links (tasks, alerts, bookmarks) land there with their query kept; the gate is the same (customer
// service and Sales), checked before the move.
export default async function VaChat({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([vaPage('/staff/visitors?view=chat', ['cs', 'sales']), searchParams]);
  redirect(chatMovedTo('staff', sp));
}
