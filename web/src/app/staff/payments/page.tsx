import { redirect } from 'next/navigation';
import { vaPage } from '@/server/va';
import { movedTo } from '@/features/admin/hubs';

export const dynamic = 'force-dynamic';

// Payments by day (0151) is Finance > Money > By day since the r27 consolidation: old links keep their dates and filters.
export default async function VaPayments({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([vaPage('/staff/money?tab=day', ['finance']), searchParams]);
  redirect(movedTo('/staff/money', 'day', sp));
}
