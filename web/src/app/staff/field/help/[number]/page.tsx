import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FdIcon } from '@/features/field/icons';
import { bookingCan, FIELD } from '@/features/shared-pages/viewer';
import { RenterHelp, type HelpBooking } from '@/features/field-portal/RenterHelp';
import { shiftText } from '@/features/field-portal/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Help the renter', path: '/staff/field/help', noindex: true, description: 'Take payment, the deposit, check the licence and get the agreement signed.' });

// One booking for renter help (r35 part X): what is open in four tiles, then one button per thing to do. What field staff may do
// here is bookingCan(FIELD): payment, the deposit, the licence in person and the signature; never a refund or a void.
export default async function HelpOne({ params }: { params: Promise<{ number: string }> }) {
  const { number } = await params;
  if (!/^[A-Za-z0-9-]{3,30}$/.test(number)) notFound();
  const { user } = await requireStaff('field', `/staff/field/help/${number}`);
  const b = await door<HelpBooking>(user.id, 'field_read', 'help_booking', { booking: number }).catch(() => null);
  if (!b) notFound();
  const readers = await door<Array<{ id: string; label: string }>>(user.id, 'ops_read', 'terminal_readers').catch(() => []);
  return (
    <>
      <p><Link prefetch={false} className="fd-back" href="/staff/field"><FdIcon name="back" />Today</Link></p>
      <header className="fp-hello"><h1>{b.renter?.name ?? 'The renter'}</h1><p>{b.number}</p></header>
      <p className="small fp-stack">{b.vehicle}. {shiftText(b.pickup_at, b.return_at).replace(' to ', ' until ')}.</p>
      <RenterHelp b={b} can={bookingCan(FIELD)} readers={Array.isArray(readers) ? readers : []} />
    </>
  );
}
