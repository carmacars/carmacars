import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { torontoParts } from '@/lib/dates';
import { money } from '@/lib/format';
import { rpc } from '@/lib/db/repo';
import { when } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ExtendForm } from '@/features/portal/SelfService';
import { ExtendOffers, type ExtOffers } from '@/features/portal/ExtendOffers';
import { Disclosure, PortalCard } from '@/components/portal-ui';
import { myBooking } from '@/server/portal/data';
import { cardPayments } from '@/server/card-provider';
import { cardOn } from '@/features/money/card-pay';
import { PayOffline } from '@/features/money/PayOffline';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Extend your rental', path: '/account/bookings', noindex: true, description: 'Keep the car longer: pick how long and pay with your card on file.' });

const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

// Extend (02 section 7.5; 0480): the six offers of public.my_extension_offers with one tap to pay, an open extension to
// pay, or a request for another date (public.my_extension_preview).
export default async function ExtendPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'extend');
  if (!['confirmed', 'on_rent'].includes(b.status)) redirect(bookingPath(b.booking_number));
  const [offers, card] = await Promise.all([(rpc('my_extension_offers', { p_booking: b.id }, { role: 'authenticated', userId: user.id }).catch(() => null)) as unknown as Promise<ExtOffers | null>, cardPayments()]);
  // r50 hotfix2: no card processor: the extension is asked for, then paid by e-Transfer or direct deposit (no card button)
  const cardOff = !cardOn(card);
  const r = torontoParts(b.return_at);
  const open = b.extensions.find((e) => ['requested', 'approved'].includes(e.status));
  const custom = <ExtendForm number={b.booking_number} returnDate={r.date} returnTime={hm(Math.round(r.minutes / 30) * 30 % 1440)} approved={null} />;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Extend your rental</h1>
      <p className="lead">{offers?.offers && offers.discount_bps ? `Extensions are ${offers.discount_bps / 100}% off the regular price. ` : ''}Your return: {when(b.return_at)}</p>
      <PortalCard id="extend" className="ext-card" title={open?.status === 'approved' ? 'Pay for your extension' : open ? 'Your request' : 'How much longer do you need?'} testId="extend-panel">
        {open?.status === 'requested' ? <p role="status">Your request to return on {when(open.new_return_at)} ({money(open.total_cents ?? 0, { cents: true })}) is with our team. Once approved, you pay here.</p>
          : open?.status === 'approved' && cardOff ? <PayOffline card={card} reference={b.booking_number} amount={money(open.total_cents ?? 0, { cents: true })} title="Pay for your extension by e-Transfer or direct deposit" testId="extend-pay-offline" />
          : open?.status === 'approved' ? <ExtendForm number={b.booking_number} returnDate={r.date} returnTime={hm(r.minutes)} approved={{ id: open.id, total_cents: open.total_cents ?? 0, new_return_at: open.new_return_at }} hasCard={offers ? !!offers.card : true} />
          : offers?.offers && !cardOff ? <>
              <ExtendOffers data={offers}><Disclosure summary="Another date and time" testId="extend-custom">{custom}</Disclosure></ExtendOffers>
            </>
          : <>
              {offers?.message && <p className="small" data-testid="extend-message">{offers.message}</p>}
              {custom}
            </>}
      </PortalCard>
    </>
  );
}
