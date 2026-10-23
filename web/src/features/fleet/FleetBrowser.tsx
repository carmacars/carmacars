'use client';
import { useRouter } from 'next/navigation';
import { useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { CarCard } from '@/components/CarCard';
import { DateRange } from '@/features/calendar/DateRange';
import { TimeSelect } from '@/features/calendar/TimeSelect';
import { browserRpc } from '@/lib/browser-rpc';
import { shortDate, torontoInstant, torontoToday, validIso, validTime } from '@/lib/dates';
import { money, plural } from '@/lib/format';
import type { CarRow } from '@/lib/types';

// The fleet (docs/blueprint/01-public-site.md 4.2, prototype fleet page). The list of cars is in the
// static HTML; filters apply in the browser, and chosen dates ask public.search_available which cars
// are free for the whole stretch, with the rental charge from the database.
type Avail = { vehicle_id: string; billable_days: number; rental_charge_cents: number; total_cents: number };
const SEATS = [['any', 'Any'], ['2', '2'], ['5', '5+'], ['7', '7+']] as const;

type Props = { cars: CarRow[]; labels: Record<string, string>; classes: string[]; maxDays: number };

// The server renders every car with the default filters (useSearchParams would leave only a skeleton in the
// static HTML, and crawlers would see no car links). After hydration the address's filters and dates are
// read once and the browser is remounted with them.
export function FleetBrowser(props: Props) {
  const [qs, setQs] = useState<string | null>(null);
  // the address is browser-only state, read once after hydration (the server has no query on a static page)
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setQs(window.location.search); }, []);
  return <Browser key={qs ?? ''} {...props} p={new URLSearchParams(qs ?? '')} sync={qs !== null} />;
}

function Browser({ cars, labels, classes, maxDays, p, sync }: Props & { p: URLSearchParams; sync: boolean }) {
  const router = useRouter();
  const today = torontoToday();
  const prices = cars.map((c) => c.daily_rate_cents / 100);
  const minP = Math.floor(Math.min(...prices) / 10) * 10; const maxP = Math.ceil(Math.max(...prices) / 10) * 10;

  const [dates, setDates] = useState(() => {
    const f = p.get('from'); const t = p.get('to');
    return validIso(f) && validIso(t) && f >= today ? { from: f, to: t } : { from: '', to: '' };
  });
  const [tf, setTf] = useState(validTime(p.get('tf')) ? p.get('tf')! : '10:00');
  const [tt, setTt] = useState(validTime(p.get('tt')) ? p.get('tt')! : '10:00');
  const [cls, setCls] = useState<string[]>(() => (p.get('cls') ?? '').split(',').filter((c) => classes.includes(c)));
  const [seats, setSeats] = useState(p.get('seats') ?? 'any');
  const [trans, setTrans] = useState(p.get('trans') ?? 'any');
  const [max, setMax] = useState(() => { const m = Number(p.get('max')); return m >= minP && m <= maxP ? m : maxP; });
  const [sort, setSort] = useState(p.get('sort') ?? 'featured');
  // the site search box (the WebSite SearchAction of 0061): words matched against make, model, trim, class and body
  const [q, setQ] = useState(() => (p.get('q') ?? '').trim().slice(0, 60));
  const qText = q;
  const words = useMemo(() => qText.toLowerCase().split(/\s+/).filter(Boolean), [qText]);
  const [showBooked, setShowBooked] = useState(false);
  const [res, setRes] = useState<{ key: string; avail: Map<string, Avail> | null; failed: boolean } | null>(null);
  const [panel, setPanel] = useState(false);
  const [, startTransition] = useTransition();
  const openBtn = useRef<HTMLButtonElement>(null);
  // the dates and sorting bar folds to one line (the owner's request of October 23, 2026): open at the top of the page,
  // folded by itself on a phone once the visitor scrolls into the cars, open again back at the top; the arrow folds or
  // opens it at any width (on a desktop folding also hides the filters column, so the cars take the whole width)
  const [folded, setFolded] = useState(false);
  const top = useRef<HTMLDivElement>(null);
  const bar = useRef<HTMLElement>(null);
  const mode = p.get('mode') ?? '';
  const hasDates = !!(dates.from && dates.to);

  // live availability for the chosen dates, kept with the dates it answers
  const availKey = hasDates ? `${dates.from} ${tf} ${dates.to} ${tt}` : '';
  useEffect(() => {
    if (!availKey) return;
    let live = true;
    browserRpc<Avail[]>('search_available', { p_pickup: torontoInstant(dates.from, tf), p_return: torontoInstant(dates.to, tt), p_filters: {} })
      .then((rows) => { if (live) setRes({ key: availKey, avail: new Map(rows.map((r) => [r.vehicle_id, r])), failed: false }); })
      .catch(() => { if (live) setRes({ key: availKey, avail: null, failed: true }); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [availKey]);
  const current = !!availKey && res?.key === availKey;
  const avail = current ? res!.avail : null;
  const failed = current ? res!.failed : false;
  const loading = !!availKey && !current;

  // reflect state in the address bar (canonical stays /cars)
  useEffect(() => {
    const q = new URLSearchParams();
    if (hasDates) { q.set('from', dates.from); q.set('to', dates.to); q.set('tf', tf); q.set('tt', tt); }
    if (mode) q.set('mode', mode);
    if (cls.length) q.set('cls', cls.join(','));
    if (seats !== 'any') q.set('seats', seats);
    if (trans !== 'any') q.set('trans', trans);
    if (max < maxP) q.set('max', String(max));
    if (sort !== 'featured') q.set('sort', sort);
    if (qText) q.set('q', qText);
    const s = q.toString();
    if (sync) window.history.replaceState(null, '', `/cars${s ? '?' + s : ''}`);
  }, [sync, hasDates, dates.from, dates.to, tf, tt, mode, cls, seats, trans, max, sort, maxP, qText]);

  useEffect(() => { document.body.style.overflow = panel ? 'hidden' : ''; return () => { document.body.style.overflow = ''; }; }, [panel]);

  // fold on a phone once the cars have scrolled 200px under the stuck bar; open again once the bar is back in its place.
  // Measured from a mark above the bar (the bar's own height changes when it folds), with a wide gap between the two
  // points so the page moving up when the bar folds never opens it again. Only crossing a point acts, so the arrow wins
  // in between.
  useEffect(() => {
    const phone = window.matchMedia('(max-width: 39.99rem)');
    let past = false; let raf = 0;
    const check = () => {
      raf = 0;
      if (!top.current || !bar.current) return;
      const y = top.current.getBoundingClientRect().top; const stick = parseFloat(getComputedStyle(bar.current).top) || 0;
      if (!past && y < stick - 200) { past = true; if (phone.matches) setFolded(true); }
      else if (past && y > stick - 1) { past = false; if (phone.matches) setFolded(false); }
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(check); };
    check();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => { window.removeEventListener('scroll', onScroll); if (raf) cancelAnimationFrame(raf); };
  }, []);

  const rows = useMemo(() => {
    const list = cars.map((c, i) => {
      let ok = true;
      if (cls.length && !cls.some((k) => c.classes.includes(k))) ok = false;
      const st = c.seats ?? 0;
      if (seats === '2' && st !== 2) ok = false; if (seats === '5' && st < 5) ok = false; if (seats === '7' && st < 7) ok = false;
      if (trans !== 'any' && c.transmission !== trans) ok = false;
      if (c.daily_rate_cents / 100 > max) ok = false;
      if (words.length) { const hay = [c.year, c.make, c.model, c.trim, c.body_style, c.fuel, ...c.classes.map((k) => labels[k] ?? k)].join(' ').toLowerCase(); if (!words.every((w) => hay.includes(w))) ok = false; }
      const a = avail?.get(c.vehicle_id);
      const busy = ok && hasDates && avail !== null && !a;
      const sortPrice = a ? a.rental_charge_cents : c.daily_rate_cents;
      return { c, i, ok, busy, a, sortPrice };
    });
    const by: Record<string, (x: typeof list[number], y: typeof list[number]) => number> = {
      'price-asc': (x, y) => x.sortPrice - y.sortPrice, 'price-desc': (x, y) => y.sortPrice - x.sortPrice,
      name: (x, y) => `${x.c.make} ${x.c.model}`.localeCompare(`${y.c.make} ${y.c.model}`),
      seats: (x, y) => (y.c.seats ?? 0) - (x.c.seats ?? 0) || x.sortPrice - y.sortPrice, featured: (x, y) => x.i - y.i
    };
    // real cars always before the sample cars (0104), whatever the sort
    return list.sort((x, y) => Number(x.busy) - Number(y.busy) || Number(!!x.c.is_sample) - Number(!!y.c.is_sample) || (by[sort] ?? by.featured!)(x, y));
  }, [cars, cls, seats, trans, max, avail, hasDates, sort, words, labels]);

  const shown = rows.filter((r) => r.ok && (!r.busy || showBooked));
  const free = shown.filter((r) => !r.busy).length;
  const booked = rows.filter((r) => r.ok && r.busy).length;
  const chips: [string, string][] = [
    ...cls.map((k) => ['cls:' + k, labels[k] ?? k] as [string, string]),
    ...(seats !== 'any' ? [['seats', seats === '2' ? '2 seats' : `${seats}+ seats`] as [string, string]] : []),
    ...(trans !== 'any' ? [['trans', trans] as [string, string]] : []),
    ...(max < maxP ? [['max', `Up to ${money(max * 100)}`] as [string, string]] : []),
    ...(qText ? [['q', `"${qText}"`] as [string, string]] : [])
  ];
  const clearAll = () => { setCls([]); setSeats('any'); setTrans('any'); setMax(maxP); setQ(''); };
  const removeChip = (k: string) => { if (k.startsWith('cls:')) setCls(cls.filter((c) => c !== k.slice(4))); else if (k === 'seats') setSeats('any'); else if (k === 'trans') setTrans('any'); else if (k === 'q') setQ(''); else setMax(maxP); };
  const carHref = (slug: string) => {
    if (!hasDates) return `/cars/${slug}`;
    const q = new URLSearchParams({ from: dates.from, to: dates.to, tf, tt });
    if (mode === 'delivery') { q.set('deliver', '1'); q.set('collect', '1'); }
    return `/cars/${slug}?${q}`;
  };
  const heading = hasDates ? `${free ? 'Cars free' : 'No cars free'} ${shortDate(dates.from)} to ${shortDate(dates.to)}` : shown.length < cars.length ? 'Cars that match' : 'Every car';
  const closePanel = () => { setPanel(false); openBtn.current?.focus(); };
  const summary = [hasDates ? `${shortDate(dates.from)} to ${shortDate(dates.to)}` : 'Any dates', chips.length ? `Filters · ${chips.length} active` : 'Filters', plural(shown.length, 'car')].join(' · ');

  return (
    <div className={[loading && 'is-loading', folded && 'is-folded'].filter(Boolean).join(' ') || undefined}>
      <div ref={top} aria-hidden="true"></div>
      <section className={`fleet-bar${folded ? ' is-folded' : ''}`} aria-label="Dates and sorting" ref={bar}>
        <div className="fleet-bar__fold" id="fleet-options" data-testid="fleet-options">
          <div className="wrap fleet-bar__in">
            <div className="field fleet-bar__dates">
              <DateRange id="fl" from={dates.from} to={dates.to} min={today} today={today} maxDays={maxDays} onChange={(v) => startTransition(() => setDates(v))} />
            </div>
            <TimeSelect id="fl-tf" label="Pickup time" value={tf} onChange={setTf} />
            <TimeSelect id="fl-tt" label="Return time" value={tt} onChange={setTt} />
            <div className="field fleet-bar__sort">
              <label className="label" htmlFor="fl-sort">Sort by</label>
              <select className="select" id="fl-sort" value={sort} onChange={(e) => setSort(e.target.value)}>
                <option value="featured">Our order</option><option value="price-asc">Price, low to high</option><option value="price-desc">Price, high to low</option>
                <option value="seats">Seats, most first</option><option value="name">Name, A to Z</option>
              </select>
            </div>
            <button type="button" className="btn btn--ghost fleet-bar__filters" aria-expanded={panel} aria-controls="filter-panel" ref={openBtn} onClick={() => setPanel(true)}>
              <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 6h14M6 10h8M8.5 14h3" fill="none" stroke="currentColor" strokeWidth="2" /></svg>Filters<b>{chips.length ? ` (${chips.length})` : ''}</b>
            </button>
          </div>
        </div>
        <div className="wrap fleet-bar__tog">
          <button type="button" className="fleet-bar__toggle" aria-expanded={!folded} aria-controls="fleet-options" data-testid="fleet-fold" onClick={() => setFolded(!folded)}>
            {folded ? <><span className="vh">Show dates and filters: </span><span className="fleet-bar__sum">{summary}</span></> : <span className="vh">Hide dates and filters</span>}
            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M5 12.5l5-5 5 5" fill="none" stroke="currentColor" strokeWidth="2" /></svg>
          </button>
        </div>
      </section>
      <section className="section--tight fleet-main">
        <div className="wrap fleet-layout">
          <aside className={`filters${panel ? ' is-open' : ''}`} id="filter-panel" aria-label="Filters" onKeyDown={(e) => { if (e.key === 'Escape' && panel) closePanel(); }}>
            <form onSubmit={(e) => e.preventDefault()}>
              <div className="filters__head"><h2 className="d3">Filters</h2><button type="button" className="modal__close" aria-label="Close filters" onClick={closePanel}>×</button></div>
              <fieldset className="filters__group"><legend>Type <span className="small muted">(any of these)</span></legend>
                {classes.map((c) => (
                  <label className="check" key={c}><input type="checkbox" name="cls" value={c} checked={cls.includes(c)} onChange={(e) => setCls(e.target.checked ? [...cls, c] : cls.filter((x) => x !== c))} /><span>{labels[c] ?? c}</span></label>
                ))}
              </fieldset>
              <fieldset className="filters__group"><legend>Seats</legend>
                <div className="seg">{SEATS.map(([v, l]) => <label key={v}><input type="radio" name="seats" value={v} checked={seats === v} onChange={() => setSeats(v)} />{l}</label>)}</div>
              </fieldset>
              <fieldset className="filters__group"><legend>Transmission</legend>
                <div className="seg">{['any', 'Automatic', 'Manual'].map((v) => <label key={v}><input type="radio" name="trans" value={v} checked={trans === v} onChange={() => setTrans(v)} />{v === 'any' ? 'Any' : v}</label>)}</div>
              </fieldset>
              <div className="filters__group">
                <label className="filters__legend" htmlFor="fl-max">Daily rate</label>
                <input className="range" type="range" id="fl-max" min={minP} max={maxP} step={10} value={max} aria-describedby="fl-max-out"
                  style={{ ['--fill' as string]: `${((max - minP) / Math.max(1, maxP - minP)) * 100}%` }} onChange={(e) => setMax(Number(e.target.value))} />
                <p className="small strong num" id="fl-max-out">{max >= maxP ? 'Any price' : `Up to ${money(max * 100)} a day`}</p>
              </div>
              <div className="filters__group">
                <label className="check"><input type="checkbox" checked={showBooked} onChange={(e) => setShowBooked(e.target.checked)} /><span>Also show cars booked for my dates</span></label>
              </div>
              <div className="filters__foot">
                <button type="button" className="btn btn--quiet" onClick={clearAll}>Clear all</button>
                <button type="button" className="btn btn--primary" onClick={closePanel}>{shown.length ? 'Show cars' : 'No cars match'}</button>
              </div>
            </form>
          </aside>
          <div className="fleet-results">
            <div className="fleet-results__head">
              <p className="d3" aria-live="polite">{heading}</p>
              <div className="chips">
                {chips.map(([k, l]) => <button key={k} type="button" className="chip" onClick={() => removeChip(k)}><span className="vh">Remove filter </span>{l}<i aria-hidden="true">×</i></button>)}
                {chips.length > 1 && <button type="button" className="chip chip--clear" onClick={clearAll}>Clear all</button>}
              </div>
            </div>
            {failed && <p className="alert alert--warn"><span className="alert__title">Live availability is not loading</span><span>You can still send a request and we will confirm.</span></p>}
            {hasDates && booked > 0 && !showBooked && <p className="alert"><span>Some cars that match are booked for those dates.</span> <button type="button" className="link" onClick={() => setShowBooked(true)}>Show them anyway</button></p>}
            {loading && <ul className="fleet-grid fleet-grid--skeleton" aria-hidden="true">{Array.from({ length: 3 }, (_, i) => <li key={i}><div className="skeleton sk-img"></div><div className="skeleton sk-title"></div><div className="skeleton sk-line" style={{ width: '40%' }}></div></li>)}</ul>}
            <ul className="fleet-grid" id="fleet-grid" hidden={!shown.length} aria-busy={loading || undefined}>
              {shown.map(({ c, busy, a }) => (
                <li key={c.slug} className={busy ? 'is-booked' : undefined}>
                  <CarCard c={c} labels={labels} tag="h2" href={carHref(c.slug)} booked={busy}
                    price={a ? money(a.rental_charge_cents) : undefined} unit={a ? `${plural(a.billable_days, 'day')}, before HST` : undefined} />
                </li>
              ))}
            </ul>
            {!shown.length && (
              <div className="empty">
                <p className="d2">{hasDates && booked ? 'Everything is booked for these dates.' : 'No cars match.'}</p>
                <p className="muted measure">{hasDates && booked ? 'Try different dates or ask us.' : 'Nothing in the fleet fits every filter for those dates. Loosen a filter, or change the dates by a day or two.'}</p>
                <div className="row">
                  <button type="button" className="btn" onClick={clearAll}>Clear filters</button>
                  <button type="button" className="btn btn--ghost" onClick={() => setDates({ from: '', to: '' })}>Clear dates</button>
                  {hasDates && <button type="button" className="btn btn--ghost" onClick={() => router.push('/contact?topic=dates')}>Ask us</button>}
                </div>
              </div>
            )}
          </div>
        </div>
      </section>
    </div>
  );
}
