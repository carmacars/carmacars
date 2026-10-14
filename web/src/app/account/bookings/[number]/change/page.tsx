import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { torontoParts } from '@/lib/dates';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { amendmentBlocks, moneyLine } from '@/features/agreement/amendment';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ChangeForm } from '@/features/portal/SelfService';
import { ChangeAnswer } from '@/features/portal/ChangeAnswer';
import { Countdown } from '@/features/portal/Countdown';
import { myBooking } from '@/server/portal/data';
import { changeFacts } from '@/server/portal/change';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Change your booking', path: '/account/bookings', noindex: true, description: 'A change to a confirmed booking: ask for one, or answer one we suggested.' });

const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
const plain = (s: string) => s.replace(/\*\*/g, '');

// A change to a confirmed booking (02 section 7.4, migration 0040). A change staff proposed, or one the renter asked
// for that staff approved, is answered here: the amendment to read, the money, the deadline, then sign (and pay any
// difference) or decline. Otherwise the renter asks for new dates.
export default async function ChangePage({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'change');
  const waiting = b.change_requests.find((c) => ['proposed', 'approved'].includes(c.status));
  const asked = b.change_requests.find((c) => c.status === 'requested');
  if (!waiting && b.status !== 'confirmed') redirect(bookingPath(b.booking_number));
  if (waiting) {
    const f = await changeFacts(waiting.id, user.id);
    const d = f.change.total_difference_cents ?? 0;
    const stamp = `${d}:${f.change.accept_by ?? ''}:${(f.change.after?.total_cents as number | undefined) ?? ''}`;
    const signedUnpaid = f.amendment?.status === 'signed' && f.change.status !== 'applied';
    return (
      <>
        <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
        <header className="stack">
          <p className="pt-kicker">{f.change.requested_by_role === 'staff' ? 'A change we suggest' : 'Your change is approved'}</p>
          <h1 className="d2">Review the change to your booking</h1>
          {f.change.note && <p className="lead" data-testid="change-reason">{f.change.note}</p>}
          {f.change.accept_by && <p className="muted">Answer by <b>{when(f.change.accept_by)}</b>. Until you accept, your booking stays as it is.</p>}
          {f.change.accept_by && f.open && <Countdown until={f.change.accept_by} label="Time left to answer" />}
        </header>
        <div className="pt-split">
          <div className="stack-lg">
            <section className="pt-card" aria-labelledby="pt-chg"><h2 className="d4" id="pt-chg">What changes</h2>
              <div className="table-scroll" tabIndex={0} role="region" aria-label="What changes">
                <table className="data" data-testid="change-rows"><thead><tr><th scope="col">Item</th><th scope="col">Now</th><th scope="col">After</th></tr></thead>
                  <tbody>{f.rows.map((r) => <tr key={r.label}><th scope="row">{r.label}</th><td>{r.before}</td><td><b>{r.after}</b></td></tr>)}</tbody></table>
              </div>
              <p data-testid="change-money">{d > 0 ? <>Extra to pay: <b>{money(d, { cents: true })}</b> (HST included)</> : d < 0 ? <>Back to you: <b>{money(-d, { cents: true })}</b> (HST included)</> : 'The price stays the same.'}</p>
            </section>
            <section className="pt-card" aria-labelledby="pt-amend"><h2 className="d4" id="pt-amend">The amendment you sign</h2>
              <AgreementView blocks={amendmentBlocks(f)} id="amendment" label="Booking amendment" />
            </section>
          </div>
          <aside className="pt-split__aside stack-lg">
            <section className="pt-card" aria-labelledby="pt-ans"><h2 className="d4" id="pt-ans">Your answer</h2>
              {f.open
                ? <ChangeAnswer number={b.booking_number} requestId={waiting.id} stamp={stamp} legalName={f.renter.legal_name} payLine={plain(moneyLine(f))} signedUnpaid={signedUnpaid} />
                : <p role="status">The time to answer has passed. Your booking stays as it was.</p>}
            </section>
          </aside>
        </div>
      </>
    );
  }
  const p = torontoParts(b.pickup_at), r = torontoParts(b.return_at);
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Ask to change dates</h1>
      <section className="pt-card" style={{ maxWidth: '40rem' }}>
        {asked ? <p role="status">You already asked for a change. We will answer soon; it is on the booking page.</p>
          : <ChangeForm number={b.booking_number} pickupDate={p.date} pickupTime={hm(p.minutes)} returnDate={r.date} returnTime={hm(r.minutes)} />}
      </section>
    </>
  );
}
