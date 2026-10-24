import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { HandoverRun } from '@/features/handover/HandoverRun';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-out or check-in', path: '/admin/bookings', noindex: true, description: 'The check-out or check-in checklist of a booking.' });

export default async function AdminHandover({ params }: { params: Promise<{ number: string; job: string }> }) {
  const { number, job } = await params;
  const n = decodeURIComponent(number);
  const { user } = await page(`/admin/bookings/${n}`);
  return <HandoverRun userId={user.id} job={job} number={n} base={`/admin/bookings/${encodeURIComponent(n)}`} />;
}
