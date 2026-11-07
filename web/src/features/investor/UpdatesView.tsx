'use client';
import { useMemo, useState } from 'react';
import { AREAS, filterUpdates, type Area, type Update } from './updates';

const day = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${d}T12:00:00Z`));

// The investor Updates page (release 29): a search box and an area filter over every release, newest first.
export function UpdatesView({ updates, preview = false }: { updates: Update[]; preview?: boolean }) {
  const [q, setQ] = useState('');
  const [area, setArea] = useState<Area | ''>('');
  const shown = useMemo(() => filterUpdates(updates, q, area), [updates, q, area]);
  const count = shown.reduce((n, u) => n + u.areas.reduce((m, a) => m + a.items.length, 0), 0);
  return (
    <section className="stack iv-updates" aria-labelledby="iv-updates-h" data-testid="investor-updates">
      <div className="pt-card">
        <h1 className="d3" id="iv-updates-h">Updates</h1>
        <p className="muted">Every release of the CarmaCars platform since the first build, newest first, and what each one added.</p>
        {preview && <p className="small muted" data-testid="updates-preview">Admin preview: investors see this page in their portal.</p>}
        <div className="iv-updates__tools" role="search">
          <label className="field"><span className="label">Search</span>
            <input className="input" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="For example: deposit, owners, app" data-testid="updates-search" /></label>
          <label className="field"><span className="label">Area</span>
            <select className="select" value={area} onChange={(e) => setArea(e.target.value as Area | '')} data-testid="updates-area">
              <option value="">Every area</option>{AREAS.map((a) => <option key={a} value={a}>{a}</option>)}</select></label>
        </div>
        <p className="small muted" role="status" data-testid="updates-count">{shown.length} release{shown.length === 1 ? '' : 's'}, {count} item{count === 1 ? '' : 's'}</p>
      </div>
      {shown.map((u) => (
        <article key={u.release} className="pt-card iv-release" aria-labelledby={`rel-${u.release}`} data-testid={`release-${u.release}`}>
          <header className="iv-release__head">
            <h2 className="d4" id={`rel-${u.release}`}>{u.title}</h2>
            <time className="small muted" dateTime={u.date}>Live {day(u.date)}</time>
          </header>
          <p>{u.summary}</p>
          {u.areas.map((a) => (
            <div key={a.area} className="iv-release__area">
              <h3 className="label">{a.area}</h3>
              <ul className="small">{a.items.map((i) => <li key={i}>{i}</li>)}</ul>
            </div>))}
        </article>))}
      {!shown.length && <p className="pt-card muted" data-testid="updates-none">Nothing matches. Try another word or every area.</p>}
    </section>
  );
}
