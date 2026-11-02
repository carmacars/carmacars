import { redirect } from 'next/navigation';

// r27 consolidation's read-only Marketplace for Sales is now Sales > Marketing (migration 0510): the old address goes there.
export const dynamic = 'force-dynamic';
export default async function StaffMarketplace({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  redirect(sp.car && /^[0-9a-f-]{36}$/.test(sp.car) ? `/staff/marketing?car=${sp.car}` : '/staff/marketing');
}
