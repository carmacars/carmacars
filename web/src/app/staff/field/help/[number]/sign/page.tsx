import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { SignNowPage } from '@/features/handover/SignNowPage';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign now on this device', path: '/staff/field/help', noindex: true, description: 'The renter signs the rental agreement on this device.' });

// Renter help (r35 part X): the renter signs on the field staff member's phone, in person (the database checks who may, 0130).
export default async function HelpSign({ params }: { params: Promise<{ number: string }> }) {
  const { number } = await params;
  if (!/^[A-Za-z0-9-]{3,30}$/.test(number)) notFound();
  const { user } = await requireStaff('field', `/staff/field/help/${number}/sign`);
  const b = await door<{ id: string } | null>(user.id, 'field_read', 'help_booking', { booking: number }).catch(() => null);
  if (!b) notFound();
  return <SignNowPage userId={user.id} booking={b.id} base={`/staff/field/help/${number}`} backLabel="Back to the renter" />;
}
