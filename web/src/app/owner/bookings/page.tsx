import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { OwnBookingForm } from '@/features/owner/OwnerForms';
import { ownerBookings, requireOwner } from '@/server/owner/data';
import type { OwnerBooking } from '@/features/owner/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/owner/bookings', noindex: true, description: 'Bookings on your vehicles.' });

const TZ = 'America/Toronto';
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const WEEK = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// A month of the owner's cars: each day shows the bookings on it. Renter names only where the
// database gives them (Self-Managed rentals and the owner's own bookings).
function Month({ year, month, bookings }: { year: number; month: number; bookings: OwnerBooking[] }) {
  const first = new Date(Date.UTC(year, month, 1));
  const days = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const lead = first.getUTCDay();
  const cells: Array<{ d: number; iso: string } | null> = [...Array(lead).fill(null), ...Array.from({ length: days }, (_, i) => ({ d: i + 1, iso: `${year}-${String(month + 1).padStart(2, '0')}-${String(i + 1).padStart(2, '0')}` }))];
  const on = (iso: string) => bookings.filter((b) => ymd(new Date(b.pickup_at)) <= iso && ymd(new Date(b.return_at)) >= iso);
  const title = new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(first);
  return (
    <section className="pt-card" aria-label={title}>
      <h2 className="d4">{title}</h2>
      <p className="vh">{(() => { const n = bookings.filter((b) => ymd(new Date(b.return_at)) >= `${year}-${String(month + 1).padStart(2, '0')}-01` && ymd(new Date(b.pickup_at)) <= `${year}-${String(month + 1).padStart(2, '0')}-${days}`).length; return n ? `${n} bookings this month, listed below.` : 'No bookings this month.'; })()}</p>
      <div className="ow-cal" aria-hidden="true">
        <div className="ow-cal__head">{WEEK.map((w) => <span key={w}>{w}</span>)}</div>
        <div className="ow-cal__grid">
          {cells.map((c, i) => c ? (
            <div key={i} className={`ow-cal__day${on(c.iso).length ? ' is-booked' : ''}`}>
              <span className="ow-cal__n">{c.d}</span>
              {on(c.iso).slice(0, 2).map((b) => <span key={b.booking_id} className={`ow-cal__b${b.booking_type === 'owner' ? ' is-owner' : ''}`} title={`${b.booking_number}, ${b.vehicle_name}`}>{b.booking_number}</span>)}
            </div>
          ) : <div key={i} className="ow-cal__day is-blank" />)}
        </div>
      </div>
    </section>
  );
}

export default async function OwnerBookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, home }, sp] = await Promise.all([requireOwner('/owner/bookings'), searchParams]);
  const list = await ownerBookings(user);
  const now = new Date();
  const [y, m] = ymd(now).split('-').map(Number) as [number, number];
  const bookable = home.vehicles.filter((v) => ['available', 'ready_to_list', 'cleaning', 'exit_notice'].includes(v.status)).map((v) => ({ id: v.vehicle_id, name: v.name }));
  return (
    <>
      <h1 className="d2">Bookings</h1>
      <div className="pt-split">
        <div className="stack-lg">
          <Month year={y} month={m - 1} bookings={list} />
          <Month year={m === 12 ? y + 1 : y} month={m % 12} bookings={list} />
          <section className="stack" aria-labelledby="ow-bl"><h2 className="pt-section-title" id="ow-bl">All bookings</h2>
            {list.length ? <ul className="ow-rows">{list.map((b) => <li key={b.booking_id}><span>{b.booking_number} · {b.vehicle_name}</span><span className="ow-amount">{b.booking_type === 'owner' ? 'Your booking' : money(b.rental_charge_cents, { cents: true })}</span><span className="ow-meta"><span>{when(b.pickup_at)} to {when(b.return_at)}</span><span>{b.status.replace(/_/g, ' ')}</span>{b.renter_name && <span>{b.renter_name}{b.renter_mobile ? `, ${b.renter_mobile}` : ''}</span>}</span></li>)}</ul>
              : <p className="pt-empty muted">No bookings on your vehicles yet.</p>}
            <p className="small muted">On a managed rental we show dates and status only; renter details stay with CarmaCars.</p>
          </section>
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="book-own" id="book-own"><h2 className="d4">Book my own car</h2><OwnBookingForm vehicles={bookable} initial={sp.vehicle} /></section>
        </aside>
      </div>
    </>
  );
}
