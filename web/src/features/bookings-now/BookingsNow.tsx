'use client';
import './bookings-now.css';
import Link from '@/components/Link';
import { useCallback, useEffect, useState } from 'react';
import { CarLine, Tile, Time, Who, Photo } from './parts';
import { Act, type Field } from '@/features/admin/Act';
import { ReturnedButton } from '@/features/handover/ReturnedButton';
import {
  BILL_WORDS, KIND, billed, countdown, day, depositWords, filterOut, fuel, km, money, nextPay, planWords, when,
  type BillFilter, type Board, type FreeCar, type OutFilter, type Rental
} from './model';

// Bookings > Now (migration 0330): the owner's "literal most important thing" on one screen. The numbers at the top, then
// the cars out (renter, due back with a countdown, the payment plan and the next payment, the deposit, the km and fuel at
// pickup), coming back today and tomorrow, going out in 72 hours with what is ready, the money due in 7 days and the free
// cars. Fresh data every 30 seconds while the page is visible (the Live map's pattern); the countdowns move every 30
// seconds. Every time is Toronto time. Field staff get the cars without the money (the database leaves it out).
const REFRESH_MS = 30_000;

export function BookingsNow({ initial: first, at, src, base }: { initial: Board | null; at: number; src: string; base: string | null }) {
  const [b, setB] = useState<Board | null>(first);
  const [now, setNow] = useState(at);
  const [err, setErr] = useState('');
  const [filter, setFilter] = useState<OutFilter>('all');
  const [bill, setBill] = useState<BillFilter>('all');
  // the page drawn again after an action (Mark picked up refreshes it): its fresh data replaces what the poll had
  const [seen, setSeen] = useState(first);
  if (first !== seen) { setSeen(first); if (first) setB(first); }

  const refresh = useCallback(async () => {
    try {
      const r = await fetch(src, { cache: 'no-store', credentials: 'same-origin' });
      const j = (await r.json()) as Board & { error?: string };
      if (!r.ok) throw new Error(j.error ?? 'Could not refresh');
      setB(j); setErr(''); setNow(Date.now());
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, [src]);
  useEffect(() => {
    const k = first ? null : setTimeout(() => void refresh(), 0);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_MS);
    const shown = () => { if (document.visibilityState === 'visible') void refresh(); };
    document.addEventListener('visibilitychange', shown);
    return () => { if (k) clearTimeout(k); clearInterval(t); document.removeEventListener('visibilitychange', shown); };
  }, [refresh, first]);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), REFRESH_MS); return () => clearInterval(t); }, []);

  if (!b) return <p className="bn-empty" role="alert">{err || 'Loading the board...'}</p>;
  const s = b.summary;
  const by = (rows: Rental[] | undefined) => (rows ?? []).filter((r) => billed(r, bill));
  const money7 = b.money ? by(b.money) : null;
  const out = filterOut(by(b.out), filter);
  const stale = by(b.stale);
  const outAll = by(b.out);
  const unrec = outAll.filter((r) => r.unrecorded).length, dueToday = outAll.filter((r) => r.due === 'today').length, overdue = outAll.filter((r) => r.due === 'overdue').length;
  const moneyCents = (money7 ?? []).reduce((n, r) => n + (r.pay?.next?.cents ?? 0), 0), moneyLate = (money7 ?? []).filter((r) => r.pay?.state === 'overdue').length;
  const href = (n: string) => (base ? `${base}/bookings/${encodeURIComponent(n)}` : null);
  const back = by(b.back), going = by(b.going);
  const backGroups: Array<[string, Rental[]]> = [['Overdue', back.filter((r) => r.due === 'overdue')], ['Today', back.filter((r) => r.due === 'today')], ['Tomorrow', back.filter((r) => r.due === 'tomorrow')]];
  const free = b.cars.filter((c) => c.state === 'free'), shop = b.cars.filter((c) => c.state === 'maintenance');

  return (
    <div className="bn" data-testid="bookings-now">
      <ul className="bn-sum" aria-label="Now in numbers">
        <Tile k="out" href="#out" label="Out now" n={outAll.length} note={unrec ? `${unrec} pickup${unrec === 1 ? '' : 's'} not recorded` : outAll.length ? `${outAll.length === 1 ? 'car' : 'cars'} on rent` : 'none on rent'} />
        <Tile k="today" href="#back" label="Due back today" n={dueToday} note={dueToday ? 'see Coming back' : 'none today'} />
        <Tile k="overdue" href="#back" label="Overdue" n={overdue} urgent={overdue > 0} note={overdue ? 'not back yet' : 'all on time'} />
        <Tile k="going" href="#going" label="Going out" n={going.length} note="next 72 hours" />
        {money7 && <Tile k="money" href="#money" label="Payments due" n={money7.length} urgent={moneyLate > 0} note={`${money(moneyCents)} in 7 days${moneyLate ? `, ${moneyLate} overdue` : ''}`} />}
        <Tile k="free" href="#free" label="Free cars" n={s.free} note={s.maintenance ? `${s.maintenance} in the shop` : 'ready to rent'} />
      </ul>
      <div className="bn-bar">
        <div className="bn-chips" role="group" aria-label="Bill to">
          <span className="bn-bar__k">Bill to</span>
          {([['all', 'All'], ['renter', 'Renter'], ['insurer', 'Insurer']] as Array<[BillFilter, string]>).map(([k, l]) => (
            <button key={k} type="button" className="bn-chip" aria-pressed={bill === k} onClick={() => setBill(k)} data-testid={`bn-bill-${k}`}>{l}</button>))}
        </div>
      <p className="bn-live" aria-live="polite" data-testid="bn-live">
        <span className="bn-live__dot" aria-hidden="true" />{err ? `Not refreshed: ${err}` : `Live, Toronto time. Updated ${when(new Date(now).toISOString(), now).replace('Today ', '')}`}
      </p>
      </div>


      <div className="bn-grid">
        <section className="bn-sec bn-sec--out" id="out" aria-labelledby="bn-out-h" data-testid="bn-out">
          <header className="bn-sec__head">
            <h2 id="bn-out-h">Out now <span className="bn-count">{outAll.length}</span></h2>
            <div className="bn-chips" role="group" aria-label="Show">
              {([['all', 'All'], ['late', 'Overdue'], ['today', 'Due today'], ...(b.scope === 'full' ? [['pay', 'Payment due']] : [])] as Array<[OutFilter, string]>).map(([k, l]) => (
                <button key={k} type="button" className="bn-chip" aria-pressed={filter === k} onClick={() => setFilter(k)} data-testid={`bn-filter-${k}`}>{l}</button>))}
            </div>
          </header>
          {out.length ? (
            <div className="bn-table" role="list">
              <div className="bn-thead" aria-hidden="true"><span>Car</span><span>Renter</span><span>Due back</span>{b.scope === 'full' && <><span>Next payment</span><span>Deposit</span></>}<span>Out at</span></div>
              {out.map((r) => <OutRow key={r.booking_id} r={r} now={now} href={href(r.number)} full={b.scope === 'full'} mark={b.scope === 'full' && !!base} refresh={base ? [`${base}/bookings`] : []} />)}
            </div>
          ) : <p className="bn-none">{b.out.length ? 'Nothing matches these filters.' : 'No car is out right now.'}</p>}
        </section>

        {stale.length > 0 && (
        <section className="bn-stale bn-sec--wide" aria-labelledby="bn-stale-h" data-testid="bn-stale">
          <h2 id="bn-stale-h">Ended, never closed <span className="bn-count">{stale.length}</span></h2>
          <p className="bn-sec__note">Booked, no check-in recorded, and the car has gone out again since. Close records the pickup and the return at the booked times; add the photos later.</p>
          <ul className="bn-rows">{stale.map((r) => (
            <li key={r.booking_id} className="bn-row bn-row--stale" data-testid={`bn-stale-${r.number}`}>
              <Time big={day(r.return_at)} small={`${day(r.booked_pickup_at)} to ${day(r.return_at)}`} late={false} />
              <CarLine car={r.car} number={r.number} href={href(r.number)} />
              <Who r={r.renter} booking={r.number} />
              {b.scope === 'full' && base && <Act ops action="booking_close_ended" payload={{ booking: r.booking_id }} label="Close" title={`Close ${r.number}`} testId={`bn-close-${r.number}`}
                refresh={[`${base}/bookings`]} done="Closed: the pickup and the return are recorded. Fleet has a task for the photos." fields={closeFields} />}
            </li>))}</ul>
        </section>)}

        <section className="bn-sec" id="back" aria-labelledby="bn-back-h" data-testid="bn-back">
          <header className="bn-sec__head"><h2 id="bn-back-h">Coming back <span className="bn-count">{back.length}</span></h2><p className="bn-sec__note">Overdue, today and tomorrow</p></header>
          {back.length ? backGroups.filter(([, rows]) => rows.length).map(([g, rows]) => (
            <div key={g} className="bn-group">
              <h3 className={`bn-group__h${g === 'Overdue' ? ' is-red' : ''}`}>{g}</h3>
              <ul className="bn-rows">{rows.map((r) => {
                const c = countdown(r.return_at, now);
                return (
                  <li key={r.booking_id} className={`bn-row${c.late ? ' is-late' : ''}`} data-testid={`bn-back-${r.number}`}>
                    <Time big={when(r.return_at, now).replace(/^(Today|Tomorrow) /, '')} small={c.text} late={c.late} />
                    <CarLine car={r.car} number={r.number} href={href(r.number)} compact />
                    <Who r={r.renter} booking={r.number} />
                    <span className="bn-tag">{r.return_kind === 'delivery' ? 'We collect' : r.return_kind === 'airport' ? 'Airport' : 'Drop-off'}</span>
                    {g !== 'Tomorrow' && !r.unrecorded && <ReturnedButton booking={r.booking_id} number={r.number} refresh={base ? [`${base}/bookings`] : []} testId={`bn-back-returned-${r.number}`} />}
                  </li>);
              })}</ul>
            </div>)) : <p className="bn-none">Nothing due back today or tomorrow.</p>}
        </section>

        <section className="bn-sec" id="going" aria-labelledby="bn-going-h" data-testid="bn-going">
          <header className="bn-sec__head"><h2 id="bn-going-h">Going out <span className="bn-count">{going.length}</span></h2><p className="bn-sec__note">Confirmed pickups, next 72 hours</p></header>
          {going.length ? <ul className="bn-rows">{going.map((r) => {
            const c = countdown(r.booked_pickup_at, now);
            return (
              <li key={r.booking_id} className={`bn-row bn-row--go${c.late ? ' is-late' : ''}`} data-testid={`bn-going-${r.number}`}>
                <Time big={when(r.booked_pickup_at, now)} small={c.text} late={c.late} />
                <CarLine car={r.car} number={r.number} href={href(r.number)} compact />
                <Who r={r.renter} booking={r.number} />
                <span className={`bn-tag${r.pickup_kind === 'delivery' ? ' bn-tag--dark' : ''}`} title={r.pickup_place ?? undefined}>{KIND[r.pickup_kind] ?? 'Pickup'}</span>
                {r.ready && <Readiness r={r} />}
              </li>);
          })}</ul> : <p className="bn-none">No pickups in the next 72 hours.</p>}
        </section>

        {money7 && (
          <section className="bn-sec" id="money" aria-labelledby="bn-money-h" data-testid="bn-money">
            <header className="bn-sec__head"><h2 id="bn-money-h">Money due <span className="bn-count">{money7.length}</span></h2><p className="bn-sec__note"><b>{money(moneyCents)}</b> overdue or due in 7 days</p></header>
            {money7.length ? <ul className="bn-rows">{money7.map((r) => {
              const p = nextPay(r.pay, now);
              return (
                <li key={r.booking_id} className={`bn-row bn-row--pay is-${p.tone}`} data-testid={`bn-money-${r.number}`}>
                  <span className="bn-amt"><b>{p.amount}</b><span className={`bn-state bn-state--${p.tone}`}>{r.pay?.state === 'overdue' ? 'Overdue' : r.pay?.state === 'soon' ? 'Due soon' : 'Upcoming'}</span></span>
                  <span className="bn-pay__when"><b>{p.label}</b><span>{p.sub || planWords(r.pay)}</span></span>
                  <Who r={r.renter} booking={r.number} />
                  <CarLine car={r.car} number={r.number} href={href(r.number)} compact />
                </li>);
            })}</ul> : <p className="bn-none">Nothing due in the next 7 days, nothing overdue.</p>}
          </section>
        )}

        <section className="bn-sec bn-sec--free" id="free" aria-labelledby="bn-free-h" data-testid="bn-free">
          <header className="bn-sec__head"><h2 id="bn-free-h">Free now <span className="bn-count">{free.length}</span></h2>
            <p className="bn-sec__note">{shop.length ? `${shop.length} in maintenance or cleaning` : 'Longest idle first'}{s.partner_cars ? `. Partners' cars on request: ${s.partner_cars}` : ''}</p></header>
          {b.cars.length ? <ul className="bn-cars">{[...free, ...shop].map((c) => <FreeTile key={c.id} c={c} now={now} base={base} />)}</ul> : <p className="bn-none">Every car is out or booked.</p>}
        </section>
      </div>
    </div>
  );
}

function Tick({ ok, label, state }: { ok: boolean; label: string; state?: 'wait' | 'later' }) {
  const words = ok ? 'done' : state === 'wait' ? 'scheduled' : state === 'later' ? 'at handover' : 'missing';
  return (
    <li className={`bn-tick ${ok ? 'is-ok' : state ? 'is-wait' : 'is-no'}`} title={`${label}: ${words}`}>
      <span className="bn-tick__mark" aria-hidden="true">{ok
        ? <svg viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7" /></svg>
        : state ? <svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="5" /><path d="M8 5.5V8l1.8 1.2" /></svg>
          : <svg viewBox="0 0 16 16"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" /></svg>}</span>
      <span className="bn-tick__label">{label}<span className="vh">: {words}</span></span>
    </li>
  );
}

function Readiness({ r }: { r: Rental }) {
  const x = r.ready!;
  return (
    <ul className="bn-ready" aria-label={`Ready for ${r.number}`}>
      <Tick ok={x.licence} label="Licence" />
      <Tick ok={x.agreement} label="Signed" />
      {x.paid !== undefined && <Tick ok={x.paid} label="Paid" />}
      <Tick ok={x.deposit === 'yes'} label="Deposit" state={x.deposit === 'scheduled' ? 'wait' : undefined} />
      <Tick ok={x.photos} label="Photos" state={!x.photos ? 'later' : undefined} />
    </ul>
  );
}

// Mark picked up: the record-now path of 0195 at the booked pickup time (photos, km and fuel later; Fleet gets the task).
// Its guards stay: the deposit taken or waived by an Admin, the renter's signature or an Admin's override, the agreement's
// claim check, every driver verified and the coverage confirmed. A refusal is shown as the database words it.
const closeFields: Field[] = [
  { name: 'reason', label: 'What happened', type: 'text', required: true, wide: true, value: 'Ended, never closed: the rental took place' },
  { name: 'deposit_waiver_reason', label: 'Admin: deposit not taken, waive it because', type: 'text', wide: true, hint: 'Only when the deposit is not taken. An Admin only.' },
  { name: 'signature_override_reason', label: 'Admin: no renter signature on the check-in report, because', type: 'text', wide: true, hint: 'An Admin only. Recorded on the booking.' }];
const markFields = (at: string): Field[] => [
  { name: 'at', label: 'Picked up at', type: 'datetime', value: at, required: true, hint: 'The booked pickup time. Change it if the car left at another time.' },
  { name: 'odometer_km', label: 'Odometer (km), if known', type: 'number' },
  { name: 'fuel_pct', label: 'Fuel or charge (%), if known', type: 'number' },
  { name: 'reason', label: 'Why it was not recorded', type: 'text', required: true, wide: true, value: 'Picked up; not recorded at the time' },
  { name: 'deposit_waiver_reason', label: 'Admin: deposit not taken, waive it because', type: 'text', wide: true, hint: 'Only when the deposit is not taken. An Admin only.' },
  { name: 'signature_override_reason', label: 'Admin: no renter signature on the check-in report, because', type: 'text', wide: true, hint: 'An Admin only. Recorded on the booking.' }];

function OutRow({ r, now, href, full, mark, refresh }: { r: Rental; now: number; href: string | null; full: boolean; mark: boolean; refresh: string[] }) {
  const c = countdown(r.return_at, now);
  const p = nextPay(r.pay, now);
  const dep = depositWords(r.deposit);
  const tone = r.due === 'overdue' ? ' is-overdue' : r.due === 'today' ? ' is-today' : '';
  return (
    <article className={`bn-out${tone}`} role="listitem" data-testid={`bn-out-${r.number}`} data-due={r.due}>
      <div className="bn-out__car"><CarLine car={r.car} number={r.number} href={href} /></div>
      <div className="bn-out__who"><Who r={r.renter} booking={r.number} />
        {r.unrecorded
          ? <span className="bn-unrec"><span className="bn-flag" data-testid={`bn-unrecorded-${r.number}`}>Out (pickup not recorded) since {when(r.booked_pickup_at, now)}</span>
              {mark && <Act ops action="handover_record_now" payload={{ booking: r.booking_id, kind: 'pickup' }} label="Mark picked up" variant="primary" title={`Mark ${r.number} picked up`}
                fields={markFields(r.booked_pickup_at)} refresh={refresh} done="Marked picked up. Fleet has a task to add the photos and readings." testId={`bn-mark-${r.number}`} />}</span>
          : <span className="bn-sub">Out {when(r.pickup_at, now)}{r.backdated ? ' · entered after pickup' : ''}</span>}</div>
      <div className="bn-out__due">
        <span className="bn-k">Due back</span>
        <b className="bn-out__when">{when(r.return_at, now)}</b>
        <span className={`bn-pill${c.late ? ' bn-pill--red' : r.due === 'today' ? ' bn-pill--dark' : ''}`}>{c.late ? `Overdue ${c.text.replace(' late', '')}` : `Due ${c.text}`}</span>
      </div>
      {full && <div className={`bn-out__pay is-${p.tone}`}>
        <span className="bn-k">Next payment</span>
        <span className="bn-out__payline">{p.amount && <b>{p.amount}</b>}<span className={`bn-state bn-state--${p.tone}`}>{p.label}</span></span>
        <span className="bn-sub">{planWords(r.pay)}{p.sub ? ` · ${p.sub}` : ''}{r.bill_to && r.bill_to !== 'renter' && r.pay?.plan !== 'insurer' ? ` · ${BILL_WORDS[r.bill_to]}` : ''}</span>
      </div>}
      {full && <div className="bn-out__dep"><span className="bn-k">Deposit</span><span className={dep.ok ? '' : 'bn-red'}>{dep.text}</span></div>}
      <div className="bn-out__at"><span className="bn-k">Out at</span><span>{[km(r.km_out), fuel(r.fuel_out) && `fuel ${fuel(r.fuel_out)}`].filter(Boolean).join(' · ') || 'not recorded'}</span>
        {/* r32: one tap when the car is back (overdue or due today); the database decides who may */}
        {!r.unrecorded && (r.due === 'overdue' || r.due === 'today') && <ReturnedButton booking={r.booking_id} number={r.number} refresh={refresh} testId={`bn-returned-${r.number}`} />}</div>
    </article>
  );
}

function FreeTile({ c, now, base }: { c: FreeCar; now: number; base: string | null }) {
  const shop = c.state === 'maintenance';
  const why = c.why === 'out_of_service' ? 'Out of service' : c.why === 'cleaning' ? 'Cleaning' : c.why === 'repair' ? 'Repair' : c.why === 'service' ? 'Service' : 'In the shop';
  return (
    <li className={`bn-free${shop ? ' is-shop' : ''}`} data-testid={`bn-car-${c.code ?? c.id}`}>
      <Photo car={c} size={96} />
      <span className="bn-free__text">
        <span className="bn-carline__name">{c.name}</span>
        <span className="bn-carline__id">{[c.code, c.plate].filter(Boolean).join(' · ')}</span>
        {shop
          ? <span className="bn-state bn-state--dark">{why}{c.until ? ` until ${day(c.until)}` : ''}</span>
          : <span className="bn-free__idle">{c.idle_days === null ? 'Never rented yet' : c.idle_days === 0 ? 'Back today' : `Idle ${c.idle_days} day${c.idle_days === 1 ? '' : 's'}`}</span>}
        {c.next && <span className="bn-sub">Next out {when(c.next.pickup_at, now)}{base ? <> · <Link prefetch={false} className="bn-link" href={`${base}/bookings/${encodeURIComponent(c.next.number)}`}>{c.next.number}</Link></> : ''}</span>}
      </span>
    </li>
  );
}
