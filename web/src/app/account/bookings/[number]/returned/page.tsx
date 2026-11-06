import { notFound, redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: "I've returned the car", path: '/account/bookings', noindex: true, description: 'Tell us the car is back.' });

// The booking page's "I've returned the car" button (migration 0532): the same form as the overdue notices' link.
export default async function ReturnedFromBooking({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'returned');
  const token = (await rpc('server_return_link', { p_booking: b.id, p_user: user.id }, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as string | null;
  if (!token) notFound();
  redirect(`/returned/${token}`);
}
