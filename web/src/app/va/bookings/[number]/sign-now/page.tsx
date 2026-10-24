import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { SignNowPage } from '@/features/handover/SignNowPage';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign now on this device', path: '/va', noindex: true, description: 'The renter or an additional driver signs the rental agreement on this device.' });

export default async function VaSignNow({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user, aal } = await vaPage(`/va/bookings/${n}/sign-now`);
  return <SignNowPage userId={user.id} aal={aal} booking={n} base={`/va/bookings/${encodeURIComponent(n)}`} backLabel={`Booking ${n}`} />;
}
