import { redirect } from 'next/navigation';
import { vaPage } from '@/server/va';
import { liveMovedTo } from '@/features/visitors/tabs';

export const dynamic = 'force-dynamic';

// Live visitors (migration 0060) is the staff Visitors page's Live now since the r27 consolidation (the map, Live now,
// Chat and History, as Admin's). Old links land there with their query kept; the gate is the same (customer service and
// Sales), checked before the move.
export default async function VaLive({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([vaPage('/staff/visitors', ['cs', 'sales']), searchParams]);
  redirect(liveMovedTo(sp));
}
