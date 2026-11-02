import Link from '@/components/Link';
import { CarLine, Chip, Who } from './parts';
import { BILL_WORDS, money, when, type Car } from './model';
import type { Card, Cards } from './cards';

// All bookings (Release 26 part 2, migration 0332), for an Admin and for staff alike: one clean row per booking in place
// of the table. The status in plain words, the car with its photo, the renter with Call and Text, the dates, the money
// (paid up, due, overdue, insurer billed) and Bill to; the booking number opens it. Cards on a phone, rows from 64rem.
export interface BookingRow {
  id: string; booking_number: string; status: string; vehicle_name: string; renter_name: string | null; pickup_at: string; return_at: string;
  total_due_at_booking_cents?: number | null; bill_to?: string | null; blocks_calendar?: boolean | null; awaiting_signature?: boolean; late?: string | null; checked_in_at?: string | null;
  /** a search: what matched (Booking number, Renter, Plate...) */ found?: string | null;
  /** more chips after the status (My bookings: the commission) */ tags?: Array<[string, 'red' | 'dark' | 'amber' | 'ok' | 'quiet']>;
}

const STATUS: Record<string, [string, 'red' | 'dark' | 'amber' | 'ok' | 'quiet']> = {
  requested: ['Request', 'amber'], offered: ['Offer out', 'amber'], pending_payment: ['Waiting for payment', 'amber'], tentative: ['Tentative', 'amber'],
  confirmed: ['Booked', 'dark'], on_rent: ['Out', 'red'], returned: ['Returned', 'ok'], closed: ['Closed', 'quiet'],
  cancelled: ['Cancelled', 'quiet'], declined: ['Declined', 'quiet'], expired: ['Expired', 'quiet'], no_show: ['No show', 'quiet']
};

function moneyWords(c: Card | undefined, total: number | null | undefined): { text: string; tone: 'red' | 'dark' | 'amber' | 'ok' | 'quiet' } {
  const m = c?.money;
  if (!m) return { text: total ? money(total) : '', tone: 'quiet' };
  if (m.state === 'none') return { text: 'Insurer billed', tone: 'quiet' };
  if (m.state === 'paid') return { text: 'Paid up', tone: 'ok' };
  if (m.state === 'overdue') return { text: `${money(m.next_cents ?? m.open_cents)} overdue`, tone: 'red' };
  return { text: `${money(m.open_cents)} to pay`, tone: m.state === 'soon' ? 'dark' : 'amber' };
}

export function BookingRows({ rows, cards, base, at, empty, testId = 'bookings' }: { rows: BookingRow[]; cards: Cards; base: string; at: number; empty: string; testId?: string }) {
  if (!rows.length) return <p className="bn-none" data-testid={`${testId}-empty`}>{empty}</p>;
  return (
    <div className="bk-rows" role="list" data-testid={testId}>
      <div className="bk-rows__head" aria-hidden="true"><span>Booking</span><span>Car</span><span>Renter</span><span>Dates</span><span>Money</span><span>Bill to</span></div>
      {rows.map((r) => {
        const c = cards[r.id];
        const car: Car = c?.car ?? { id: r.id, name: r.vehicle_name, code: null, plate: null, photo: null };
        const href = `${base}/bookings/${encodeURIComponent(r.booking_number)}`;
        const [word, tone] = r.awaiting_signature ? ['Waiting for signature', 'amber' as const] : STATUS[r.status] ?? [r.status.replace(/_/g, ' '), 'quiet' as const];
        const mw = moneyWords(c, r.total_due_at_booking_cents);
        const bill = c?.bill_to ?? r.bill_to ?? 'renter';
        return (
          <article key={r.id} className={`bk-row${r.late ? ' is-late' : ''}`} role="listitem" data-testid={`bk-${r.booking_number}`}>
            <div className="bk-row__st">
              <Link prefetch={false} className="bk-row__no" href={href}>{r.booking_number}</Link>
              <span className="bk-row__chips"><Chip tone={tone}>{word}</Chip>{c?.placeholder && <Chip>Placeholder</Chip>}{r.blocks_calendar === false && !c?.placeholder && <Chip>Not blocking</Chip>}{r.tags?.map(([t, k]) => <Chip key={t} tone={k}>{t}</Chip>)}</span>
              {r.late && <span className="bk-row__late" data-testid="list-late">{r.late}</span>}
              {r.found && <span className="bn-sub">Found by {r.found}</span>}
            </div>
            <div className="bk-row__car"><CarLine car={car} number="" href={null} /></div>
            <div className="bk-row__who">{r.renter_name ? <Who r={{ id: r.id, name: r.renter_name, phone: c?.phone ?? null }} /> : <span className="bn-sub">No renter</span>}</div>
            <div className="bk-row__dates"><span className="bn-k">Dates</span><span>{when(r.pickup_at, at)}</span><span className="bn-sub">to {when(r.return_at, at)}</span></div>
            <div className="bk-row__money"><span className="bn-k">Money</span><Chip tone={mw.tone}>{mw.text}</Chip></div>
            <div className="bk-row__bill"><span className="bn-k">Bill to</span><span>{BILL_WORDS[bill] ?? bill}</span></div>
          </article>
        );
      })}
    </div>
  );
}
