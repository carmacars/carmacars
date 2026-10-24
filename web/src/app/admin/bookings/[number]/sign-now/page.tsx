import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { SignNowPage } from '@/features/handover/SignNowPage';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign now on this device', path: '/admin/bookings', noindex: true, description: 'The renter or an additional driver signs the rental agreement on this device.' });

export default async function AdminSignNow({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user } = await page(`/admin/bookings/${n}/sign-now`);
  return <SignNowPage userId={user.id} booking={n} base={`/admin/bookings/${encodeURIComponent(n)}`} backLabel={`Booking ${n}`} />;
}
