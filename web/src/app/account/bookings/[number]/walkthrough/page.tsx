import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { getSettings } from '@/lib/site';
import { when } from '@/features/agreement/model';
import { Back } from '@/features/portal/Blocks';
import { bookingPath } from '@/features/portal/status';
import { StepHeader } from '@/features/portal/trip';
import { mapLink } from '@/features/portal/trip-model';
import { myBooking, myTripPhotos } from '@/server/portal/data';
import { Walkthrough } from '@/features/walkthrough/Walkthrough';
import type { Facts, Walk } from '@/features/walkthrough/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rental walkthrough', path: '/account/bookings', noindex: true, description: 'Your rental step by step: before pickup, at pickup, on the road and at the return.' });

// The rental walkthrough (migration 0291): the renter's whole rental, step by step, from what the booking already says.
export default async function RentalWalkthrough({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'walkthrough');
  const [w, s, photos, addons] = await Promise.all([
    rpc('server_my_walkthrough', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as Walk | null).catch(() => null),
    getSettings(), myTripPhotos(user),
    rpc('server_my_booking_addons', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as { items?: Array<{ prepaid_fuel?: boolean }> } | null).catch(() => null)]);
  if (!w?.enabled) notFound();
  const card = b.payments.find((p) => p.card_last4)?.card_last4 ?? null;
  const facts: Facts = {
    number: b.booking_number, status: b.status, pickupWhen: when(b.pickup_at), returnWhen: when(b.return_at),
    pickupPlace: b.pickup_place, returnPlace: b.return_place && b.return_place !== b.pickup_place ? b.return_place : null, delivery: b.pickup_method === 'delivery',
    depositText: b.deposit_cents > 0 ? money(b.deposit_cents) : null, cardLast4: card, kmTotal: b.km_allowance_total,
    overageText: b.overage_cents_per_km ? money(b.overage_cents_per_km, { cents: true }) : null,
    prepaidFuel: (addons?.items ?? []).some((a) => a.prepaid_fuel), phone: s.phone_display ?? s.phone ?? null, roadside: s.roadside_phone_display ?? s.roadside_phone ?? null,
    mapsPickup: mapLink(b.pickup_place), mapsReturn: mapLink(b.return_place), handedOver: !!b.handed_over_at, checkedIn: !!b.checked_in_at
  };
  return (<>
    <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
    <StepHeader b={b} photo={photos[b.vehicle_id] ?? null} kicker="Rental walkthrough" title="Your rental, step by step" />
    <Walkthrough initial={w} facts={facts} />
  </>);
}
