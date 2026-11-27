import './old-photos.css';
import Link from '@/components/Link';
import { SegTabs } from '@/components/ui';
import { door } from '@/server/door';
import { OneBooking } from './OneBooking';
import { Bulk } from './Bulk';
import type { Kind } from './useUploads';

// Add old photos (5185): every past booking of the last old_photos_days (60), whoever handled it, searchable by plate, car,
// renter or number, newest first; one booking's check-in or check-out photos; or a pile of photos sorted by the system. The
// same screen in the field portal, for Fleet and customer service, and for an Admin.
export interface OldRow { booking_id: string; booking_number: string; status: string; car: string | null; plate: string | null; renter: string | null;
  pickup_at: string; return_at: string | null; kinds: Kind[]; photos: Record<Kind, number> }
interface OldList { days: number; group_minutes: number; rows: OldRow[] }

// app.old_photo_bookings returns at most this many rows (5185)
const SHOWN = 60;
const at = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export async function OldPhotos({ userId, aal, base, sp }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: string; sp: Record<string, string | undefined> }) {
  const bulk = sp.mode === 'bulk';
  const q = (sp.booking ?? sp.q ?? '').slice(0, 60);
  const list = await door<OldList>(userId, 'ops_read', 'old_photo_bookings', bulk ? {} : { q }, aal).catch(() => null);
  const tabs = <SegTabs label="How to add" current={bulk ? `${base}?mode=bulk` : base} testId="op-tabs"
    items={[{ href: base, label: 'One booking', testId: 'op-tab-one' }, { href: `${base}?mode=bulk`, label: 'A pile of photos', testId: 'op-tab-bulk' }]} />;
  if (!list) return <>{tabs}<p className="alert alert--error" role="alert"><span>The past bookings did not load. Try again in a moment.</span></p></>;
  if (bulk) return <>{tabs}<Bulk gapMinutes={list.group_minutes} /></>;
  const one = sp.booking ? list.rows.find((r) => r.booking_number === sp.booking!.toUpperCase()) : null;
  if (sp.booking) {
    return (
      <>
        <p><Link prefetch={false} className="link" href={base}>All past bookings</Link></p>
        {one ? <>
          <header className="op-booking" data-testid="op-booking">
            {one.plate && <span className="op-plate">{one.plate}</span>}
            <div><h2 className="op-h2">{one.booking_number}</h2><p className="op-sub">{[one.car, one.renter].filter(Boolean).join(', ')}</p>
              <p className="op-sub">Out {at(one.pickup_at)}{one.return_at ? `, back ${at(one.return_at)}` : ', still out'}</p></div>
          </header>
          <OneBooking booking={one.booking_id} kinds={one.kinds} counts={one.photos} />
        </> : <p className="op-note" data-testid="op-not-found">Booking {sp.booking} is not a past booking of the last {list.days} days.</p>}
      </>
    );
  }
  return (
    <>
      {tabs}
      <form className="op-search" role="search" action={base} data-testid="op-search">
        <label className="vh" htmlFor="op-q">Plate, car, renter or booking</label>
        <input id="op-q" className="input" name="q" type="search" defaultValue={sp.q ?? ''} placeholder="Plate, car, renter or booking" autoComplete="off" enterKeyHint="search" data-testid="op-q" />
        <button type="submit" className="btn btn--ghost">Search</button>
      </form>
      <p className="op-note">Every booking picked up or returned in the last {list.days} days, newest first, whoever handled it.{list.rows.length >= SHOWN ? ` The newest ${SHOWN} are shown: search for an older one.` : ''}</p>
      {list.rows.length ? <ul className="op-rows" data-testid="op-rows">
        {list.rows.map((r) => (
          <li key={r.booking_id}>
            <Link prefetch={false} className="op-row" href={`${base}?booking=${encodeURIComponent(r.booking_number)}`} data-testid={`op-row-${r.booking_number}`}>
              {r.plate ? <span className="op-plate">{r.plate}</span> : <span className="op-plate is-none">No plate</span>}
              <span className="op-row__main"><b>{r.booking_number}</b><span className="op-sub">{[r.car, r.renter].filter(Boolean).join(', ')}</span>
                <span className="op-sub">Out {at(r.pickup_at)}{r.return_at ? `, back ${at(r.return_at)}` : ', still out'}</span></span>
              <span className="op-row__count">{r.photos.pickup + r.photos.return}<span className="op-sub"> photo{r.photos.pickup + r.photos.return === 1 ? '' : 's'}</span></span>
            </Link>
          </li>))}
      </ul> : <p className="op-empty" data-testid="op-empty">{q ? `No past booking matches "${q}". Try the plate without spaces, the car's model or the renter's last name.` : `No booking was picked up or returned in the last ${list.days} days.`}</p>}
    </>
  );
}
