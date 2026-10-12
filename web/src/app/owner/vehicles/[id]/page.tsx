import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money, pct } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { Back, Dl } from '@/features/portal/Blocks';
import { Checklist, day, InvoiceRows } from '@/features/owner/Blocks';
import { ExitNoticeForm } from '@/features/owner/OwnerForms';
import { OwnerUpload } from '@/features/owner/OwnerUpload';
import { MODE_LABEL, ONBOARDING_STATUS } from '@/features/owner/types';
import { ownerBookings, requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/owner/vehicles', noindex: true, description: 'One of your vehicles: status, fees, bookings and leaving.' });

const EXIT_ALLOWED = ['ready_to_list', 'available', 'on_rent', 'cleaning', 'out_of_service'];

export default async function OwnerVehicle({ params }: { params: Promise<{ id: string }> }) {
  const [{ user, home }, { id }] = await Promise.all([requireOwner('/owner/vehicles'), params]);
  const v = home.vehicles.find((x) => x.vehicle_id === id);
  if (!v) notFound();
  const bookings = (await ownerBookings(user)).filter((b) => b.vehicle_id === id);
  const exit = home.exits.find((x) => x.vehicle_id === id && x.status === 'notice');
  return (
    <>
      <Back href="/owner/vehicles">Vehicles</Back>
      <header className="stack"><p className="pt-kicker">{v.plate ?? 'Plate to come'} · {MODE_LABEL[v.management_mode] ?? v.management_mode}</p><h1 className="d2">{v.name}</h1>
        <p><span className="badge badge--outline">{v.onboarding_status && v.onboarding_status !== 'enrolled' ? ONBOARDING_STATUS[v.onboarding_status] : v.status.replace(/_/g, ' ')}</span></p></header>
      <div className="pt-split">
        <div className="stack-lg">
          {v.checklist && <section className="pt-card" aria-labelledby="ow-check"><h2 className="d4" id="ow-check">Onboarding</h2>
            {v.next && <p className="ow-car__next"><b>{v.next.item}</b>{v.next.action && <span>{v.next.action}</span>}</p>}
            <Checklist items={v.checklist} />
            {v.status === 'onboarding' && (
              <div className="pt-uploads">
                <OwnerUpload vehicleId={id} kind="ownership_permit" title="Ownership permit" hint="Both sides, flat and readable. Photos or a PDF." done={v.checklist.some((c) => c.code === 'documents' && c.status === 'done')} />
                <OwnerUpload vehicleId={id} kind="finance_party_permission" title="Lender or lessor permission" hint="If your vehicle is financed or leased: their written permission." done={false} />
                <OwnerUpload vehicleId={id} kind="owner_insurance_proof" title="Your insurance" hint="Your current insurance card. Keep your insurance until we confirm in writing." done={false} />
              </div>
            )}
            {v.estimate_cents !== null && <p className="small muted">Registry and inspection estimate: about {money(v.estimate_cents)}, which you pay directly to ServiceOntario and the inspection station, not to CarmaCars. Amounts may vary.</p>}
          </section>}
          <section className="pt-card" aria-labelledby="ow-bk"><h2 className="d4" id="ow-bk">Bookings</h2>
            {bookings.length ? <ul className="ow-rows">{bookings.map((b) => <li key={b.booking_id}><span>{b.booking_number}{b.booking_type === 'owner' ? ' · Your booking' : ''}</span><span className="ow-amount">{money(b.rental_charge_cents, { cents: true })}</span><span className="ow-meta"><span>{when(b.pickup_at)} to {when(b.return_at)}</span><span>{b.status.replace(/_/g, ' ')}</span>{b.renter_name && <span>{b.renter_name}{b.renter_mobile ? `, ${b.renter_mobile}` : ''}</span>}</span></li>)}</ul>
              : <p className="muted small">No bookings yet.</p>}
            <p><Link className="btn btn--ghost btn--sm" href={`/owner/bookings?vehicle=${id}#book-own`}>Book it for myself</Link></p>
          </section>
          <section className="pt-card" aria-labelledby="ow-inv"><h2 className="d4" id="ow-inv">Invoices</h2><InvoiceRows items={home.invoices.filter((i) => i.vehicle_id === id)} /></section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="ow-terms"><h2 className="d4" id="ow-terms">Terms</h2>
            <Dl rows={[['Insurance Fee', v.insurance_fee_cents !== null ? `${money(v.insurance_fee_cents)} a month` : 'Being set'], ['Tracker Fee', v.tracker_fee_cents !== null ? `${money(v.tracker_fee_cents)} a month` : ''], ['Revenue Share', v.revenue_share_bps !== null ? pct(v.revenue_share_bps) : ''], ['Enrollment Date', v.enrollment_date ? day(v.enrollment_date) : 'When we confirm in writing'], ['Listing', v.listing_path ? <Link key="l" href={v.listing_path}>See the listing</Link> : 'Not listed yet']]} />
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
