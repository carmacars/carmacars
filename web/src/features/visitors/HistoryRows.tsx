'use client';
import Link from '@/components/Link';
import { clockTo } from '@/lib/clock';
import { useMemo, useState } from 'react';
import { showOnMap } from '@/features/live-map/focus';
import { roleLabel } from '@/features/live-map/roles';
import { photoUrl } from '@/lib/photo';
import { DEVICE_WORDS, duration, groupByDay, outcomeOf, place, shortSource, sourceWords, type HistoryRow } from './history';

// The History rows (Release 27): one compact row a visit, grouped by day. Time, who (with what they are to us), city,
// where they came from, pages and the cars they looked at, the score and what it led to; a click opens the page trail.
// A quick search narrows the rows on the page. Never a phone or an email.
const clock = (iso: string) => clockTo(iso);
const bandOf = (s: number | null | undefined) => (s == null ? 'none' : s >= 60 ? 'hot' : s >= 30 ? 'warm' : 'cold');
const thumb = (c: NonNullable<HistoryRow['cars']>[number]) => {
  const p = c.photo;
  if (!p?.path) return null;
  const v = (p.variants ?? []).filter((x) => x?.path && x.width >= 96).sort((a, b) => a.width - b.width)[0];
  return photoUrl(v?.path ?? p.path);
};

function Row({ r, open, toggle, admin }: { r: HistoryRow; open: boolean; admin: boolean; toggle: () => void }) {
  const out = outcomeOf(r), role = roleLabel(r.roles), city = r.city ?? '', cars = r.cars ?? [], more = Math.max(0, (r.cars_n ?? r.cars_viewed) - cars.length);
  const band = bandOf(r.score);
  const [none, setNone] = useState(false);
  return (
    <li className={`vh-row vh-row--${out.key}${open ? ' is-open' : ''}`} data-testid="vh-row">
      <button type="button" className="vh-row__main" aria-expanded={open} onClick={toggle}>
        <time className="vh-t" dateTime={r.started_at}>{clock(r.started_at)}</time>
        <span className="vh-sub">{[clock(r.started_at), city || 'Unknown', shortSource(r), `${r.page_views} pg`].join(' · ')}</span>
        <span className="vh-who"><b>{r.who}</b>{role && <span className="vh-role">{role}</span>}</span>
        <span className="vh-city" title={place(r)}>{city || 'Unknown'}</span>
        <span className="vh-src" title={sourceWords(r)}>{shortSource(r)}</span>
        <span className="vh-pg">{r.page_views} pg</span>
        <span className="vh-cars" aria-label={`${r.cars_viewed} car${r.cars_viewed === 1 ? '' : 's'} viewed`}>
          {cars.map((c) => { const src = thumb(c); return src
            // eslint-disable-next-line @next/next/no-img-element -- listing photos come pre-sized
            ? <img key={c.id} src={src} alt="" title={c.name} width={28} height={20} loading="lazy" decoding="async" />
            : <span key={c.id} className="vh-cars__none" title={c.name} aria-hidden="true" />; })}
          {more > 0 && <span className="vh-cars__more">+{more}</span>}
        </span>
        <span className={`vh-dot vh-dot--${band}`} role="img" aria-label={r.score == null ? 'No score' : `Score ${r.score}`} title={r.score == null ? 'No score' : `Score ${r.score}`} />
        <span className={`vh-out vh-out--${out.key}`}>{out.label}</span>
        <span className="vh-chev" aria-hidden="true" />
      </button>
      <div className="vh-more" hidden={!open}>
        <dl className="vh-facts">
          <div><dt>Came from</dt><dd>{sourceWords(r)}</dd></div>
          <div><dt>Where</dt><dd>{[r.device ? DEVICE_WORDS[r.device] : null, place(r)].filter(Boolean).join(' · ') || 'Not known'}</dd></div>
          <div><dt>Visit</dt><dd>{duration(r.duration_s)} · {r.page_views} page{r.page_views === 1 ? '' : 's'}{r.returning ? ` · visit ${r.visit_number}` : ' · new'}</dd></div>
        </dl>
        {r.trail?.length ? (
          <ol className="vh-trail" aria-label="Pages in order">
            {r.trail.map((p, i) => <li key={i}><time dateTime={p.at}>{clock(p.at)}</time><span>{p.page ?? p.path ?? 'A page'}</span>{p.path && <code>{p.path}</code>}</li>)}
          </ol>
        ) : <p className="small muted">{r.landing ?? 'Landing page not recorded'}{r.exit && r.exit_path !== r.landing_path ? ` to ${r.exit}` : ''}. The pages are no longer kept.</p>}
        {cars.length > 0 && <p className="small muted vh-carnames">Cars: {cars.map((c) => c.name).join(', ')}{more > 0 ? ` and ${more} more` : ''}</p>}
        {!r.summarized && <p className="small muted">What it led to is worked out after the visit.</p>}
        <p className="vh-acts">
          {admin && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/live/history/${r.id}`} data-testid="vh-open">Open the visit</Link>}
          <button type="button" className="btn btn--ghost btn--sm" data-testid="vh-locate" onClick={() => setNone(!showOnMap({ session_id: r.id, renter_id: r.renter_id }))}>Show on the map</button>
          {none && <span className="small muted" role="status">Not on the map now</span>}
        </p>
      </div>
    </li>
  );
}

export function HistoryRows({ rows, now, admin = true }: { rows: HistoryRow[]; now: number; /** r27 consolidation: staff see the rows without the visit's own (Admin) page */ admin?: boolean }) {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const shown = useMemo(() => {
    const w = q.trim().toLowerCase();
    if (!w) return rows;
    return rows.filter((r) => [r.who, r.city, r.region, r.source, r.utm_source, r.utm_campaign, r.landing, roleLabel(r.roles)].some((x) => (x ?? '').toLowerCase().includes(w)));
  }, [rows, q]);
  const days = useMemo(() => groupByDay(shown, now), [shown, now]);
  return (
    <>
      <div className="vh-search">
        <label className="vh" htmlFor="vh-q">Search these visits</label>
        <input id="vh-q" className="input" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search name, city, source, page" data-testid="vh-search" autoComplete="off" />
        {q && <span className="small muted" role="status">{shown.length} of {rows.length}</span>}
      </div>
      {!shown.length ? <p className="vs-empty">Nothing on this page matches &ldquo;{q}&rdquo;.</p> : (
        <div className="vh-days" data-testid="vh-table">
          {days.map((g) => (
            <section key={g.day} className="vh-day" aria-label={g.heading}>
              <h3 className="vh-day__h"><span>{g.heading}</span><span className="vh-day__n">{g.rows.length} visit{g.rows.length === 1 ? '' : 's'}</span></h3>
              <ul className="vh-list">{g.rows.map((r) => <Row key={r.id} r={r} admin={admin} open={open === r.id} toggle={() => setOpen(open === r.id ? null : r.id)} />)}</ul>
            </section>
          ))}
        </div>
      )}
    </>
  );
}
