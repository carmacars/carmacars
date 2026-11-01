import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Incidents and claims are tabs of Bookings > Damage and claims (?tab=claims goes to Claims). An incident keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/damages', 'incidents', await searchParams, { claims: 'claims' }));
}
