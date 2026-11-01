import { redirect } from 'next/navigation';

// Bookings > Chauffeur (migration 0093) is a tab of Requests and offers since Release 26 (the owner: "We need less pages
// not more"). Old links and bookmarks land there with their status filter.
export const dynamic = 'force-dynamic';
export default async function ChauffeurAdmin({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  redirect(`/admin/requests?tab=chauffeur${sp.status ? `&status=${encodeURIComponent(sp.status)}` : ''}`);
}
