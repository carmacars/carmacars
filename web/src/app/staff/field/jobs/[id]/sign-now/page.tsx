import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { SignNowPage } from '@/features/handover/SignNowPage';
import type { FieldJob } from '@/features/field/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign now on this device', path: '/staff/field', noindex: true, description: 'The renter or an additional driver signs the rental agreement on this device.' });

// Field staff collect a signature on the booking of one of their jobs (the database checks the job).
export default async function FieldSignNow({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireStaff('field', `/staff/field/jobs/${id}/sign-now`);
  const j = await door<FieldJob | null>(user.id, 'field_read', 'job', { id }).catch(() => null);
  if (!j?.booking) notFound();
  return <SignNowPage userId={user.id} booking={j.booking.id} base={`/staff/field/jobs/${id}`} backLabel="Back to the job" />;
}
