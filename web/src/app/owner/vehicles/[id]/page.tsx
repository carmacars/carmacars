import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money, pct } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { Back, Dl } from '@/features/portal/Blocks';
import { Checklist, day, InvoiceRows } from '@/features/owner/Blocks';
import { ExitNoticeForm } from '@/features/owner/OwnerForms';
import { OwnerUpload } from '@/features/owner/OwnerUpload';
import { MODE_LABEL, ONBOARDING_STATUS, TRACKER_LATER } from '@/features/owner/types';
import { ownerBookings, requireOwner } from '@/server/owner/data';
import { door } from '@/server/door';
import { ListingCapture, type Capture } from '@/features/listing/ListingCapture';
import { ListingProgress, type Progress } from '@/features/listing/ListingProgress';
import { StartListing } from '@/features/listing/StartListing';
import { ServiceHistory } from '@/features/maintenance/OwnerHistory';
import type { OwnerHistory } from '@/features/maintenance/model';
import { rpc } from '@/lib/db/repo';
import { OwnerTermsHistory } from '@/features/owner-billing/OwnerTerms';
import type { CarTermsData } from '@/features/owner-billing/terms-shared';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/owner/vehicles', noindex: true, description: 'One of your vehicles: status, fees, bookings and leaving.' });

const EXIT_ALLOWED = ['ready_to_list', 'available', 'on_rent', 'cleaning', 'out_of_service'];

export default async function OwnerVehicle({ params }: { params: Promise<{ id: string }> }) {
  const [{ user, home }, { id }] = await Promise.all([requireOwner('/owner/vehicles'), params]);
  const v = home.vehicles.find((x) => x.vehicle_id === id);
  if (!v) notFound();
  const bookings = (await ownerBookings(user)).filter((b) => b.vehicle_id === id);
  const exit = home.exits.find((x) => x.vehicle_id === id && x.status === 'notice');
  // the car's listing: photos and progress while one is open (an owner's listing is reviewed by staff)
  const listable = !['exited', 'total_loss', 'declined'].includes(v.status) && v.management_mode !== 'turo_only';
  const current = listable ? await door<{ intake_id: string; state: string; open: boolean } | null>(user.id, 'ops_read', 'listing_current', { vehicle: id }).catch(() => null) : null;
  const [cap, prog] = current?.open
    ? await Promise.all([door<Capture>(user.id, 'ops_read', 'listing_capture', { intake: current.intake_id }), door<Record<string, Progress>>(user.id, 'ops_read', 'listing_progress', { intake: current.intake_id })])
    : [null, null];
  // the car's service history (0089), read only, while the car is with us
  const service = !['declined', 'exited', 'total_loss'].includes(v.status) ? await door<OwnerHistory>(user.id, 'ops_read', 'maint_owner', { vehicle_id: id }).catch(() => null) : null;
  // the car's terms over time and the notices (0135)
  const terms = ((await rpc('server_owner_car_terms', { p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as CarTermsData | null)?.cars.find((c) => c.vehicle_id === id) ?? null;
  return (
    <>
      <Back href="/owner/vehicles">Vehicles</Back>
      <header className="stack"><p className="pt-kicker">{v.plate ?? 'Plate to come'} · {MODE_LABEL[v.management_mode] ?? v.management_mode}</p><h1 className="d2">{v.name}</h1>
        <p><span className="badge badge--outline">{v.onboarding_status && v.onboarding_status !== 'enrolled' ? ONBOARDING_STATUS[v.onboarding_status] : v.status.replace(/_/g, ' ')}</span></p></header>
      <div className="pt-split">
        <div className="stack-lg">
          {v.checklist && <section className="pt-card" aria-labelledby="ow-check"><h2 className="d4" id="ow-check">Onboarding</h2>
            {v.next && <p className="ow-car__next"><b>{v.next.item}</b>{v.next.action && <span>{v.next.action}</span>}</p>}
            <Checklist items={v.checklist} trackers={home.trackers_available} />
            {v.status === 'onboarding' && (
              <div className="pt-uploads">
                <OwnerUpload vehicleId={id} kind="ownership_permit" title="Ownership permit" hint="Both sides, flat and readable. Photos or a PDF." done={v.checklist.some((c) => c.code === 'documents' && c.status === 'done')} />
                <OwnerUpload vehicleId={id} kind="finance_party_permission" title="Lender or lessor permission" hint="If your vehicle is financed or leased: their written permission." done={false} />
                <OwnerUpload vehicleId={id} kind="owner_insurance_proof" title="Your insurance" hint="Your current insurance card. Keep your insurance until we confirm in writing." done={false} />
              </div>
            )}
            {v.estimate_cents !== null && <p className="small muted">Registry and inspection estimate: about {money(v.estimate_cents)}, which you pay directly to ServiceOntario and the inspection station, not to CarmaCars. Amounts may vary.</p>}
          </section>}
          {listable && !current?.open && <section className="pt-card" aria-labelledby="ow-list"><h2 className="d4" id="ow-list">Listing photos</h2>
            <p className="small">{v.listing_path ? 'Your car is on the website. New photos replace the current ones once our team approves them.' : 'Take the photos for the website: 13 set angles and the odometer. We write the details, edit the backgrounds and publish the car after a review.'}</p>
            <StartListing vehicleId={id} label={v.listing_path ? 'Take new photos' : 'Add listing photos'} />
          </section>}
          {cap && prog?.[cap.intake_id] && <ListingProgress initial={prog[cap.intake_id]!} refresh={[`/owner/vehicles/${id}`]} />}
          {cap && <ListingCapture initial={cap} refresh={[`/owner/vehicles/${id}`]} />}
          <section className="pt-card" aria-labelledby="ow-bk"><h2 className="d4" id="ow-bk">Bookings</h2>
            {bookings.length ? <ul className="ow-rows">{bookings.map((b) => <li key={b.booking_id}><span>{b.booking_number}{b.booking_type === 'owner' ? ' · Your booking' : ''}</span><span className="ow-amount">{money(b.rental_charge_cents, { cents: true })}</span><span className="ow-meta"><span>{when(b.pickup_at)} to {when(b.return_at)}</span><span>{b.status.replace(/_/g, ' ')}</span>{b.renter_name && <span>{b.renter_name}{b.renter_mobile ? `, ${b.renter_mobile}` : ''}</span>}</span></li>)}</ul>
              : <p className="muted small">No bookings yet.</p>}
            <p><Link prefetch={false} className="btn btn--ghost btn--sm" href={`/owner/bookings?vehicle=${id}#book-own`}>Book it for myself</Link></p>
          </section>
          {service && <ServiceHistory h={service} />}
          <section className="pt-card" aria-labelledby="ow-inv"><h2 className="d4" id="ow-inv">Invoices</h2><InvoiceRows items={home.invoices.filter((i) => i.vehicle_id === id)} /></section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="ow-terms"><h2 className="d4" id="ow-terms">Terms</h2>
            <Dl rows={[['Insurance Fee', v.insurance_fee_cents !== null ? `${money(v.insurance_fee_cents)} a month` : 'Being set'], ...(home.trackers_available ? [['Tracker Fee', v.tracker_fee_cents !== null ? `${money(v.tracker_fee_cents)} a month` : '']] as Array<[string, string]> : []), ['Revenue Share', v.revenue_share_bps !== null ? pct(v.revenue_share_bps) : ''], ['Enrollment Date', v.enrollment_date ? day(v.enrollment_date) : 'When we confirm in writing'], ['Listing', v.listing_path ? <Link prefetch={false} key="l" href={v.listing_path}>See the listing</Link> : 'Not listed yet']]} />
            {!home.trackers_available && home.tracker_pending.includes(id) && <p className="small muted">{TRACKER_LATER}</p>}
            {terms && <OwnerTermsHistory car={terms} />}
          </section>
          <section className="pt-card" aria-labelledby="ow-exit"><h2 className="d4" id="ow-exit">Leaving</h2>
            {exit ? <p>Notice given. Exit Date <b>{day(exit.exit_date)}</b>. Transfer-back fees are paid by {exit.retransfer_fees_paid_by === 'carmacars' ? 'CarmaCars' : 'you'}.</p>
              : EXIT_ALLOWED.includes(v.status) ? <ExitNoticeForm vehicleId={id} />
              : <p className="small muted">{v.status === 'onboarding' ? 'This vehicle is still being onboarded. To stop, call or message us and we withdraw it.' : 'Notice cannot be given on this vehicle now.'}</p>}
          </section>
        </aside>
      </div>
    </>
  );
}
