import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { HandoverRun } from '@/features/handover/HandoverRun';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-out or check-in', path: '/va', noindex: true, description: 'The check-out or check-in checklist of a booking.' });

export default async function VaHandover({ params }: { params: Promise<{ number: string; job: string }> }) {
  const { number, job } = await params;
  const n = decodeURIComponent(number);
  const { user, aal } = await vaPage(`/va/bookings/${n}`);
  return <HandoverRun userId={user.id} aal={aal} job={job} number={n} base={`/va/bookings/${encodeURIComponent(n)}`} />;
}
