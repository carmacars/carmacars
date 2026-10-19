'use client';
import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { calendarAct, calendarSyncNow } from '@/server/actions/calendar-sync';

// Cars > Calendar sync (migration 0062), for Admins and Fleet: per car, the calendar links of other platforms that
// block it (import) and its own CarmaCars link to paste into them (export), with the clashes on top.
export interface FeedRow {
  id: string; platform: 'turo' | 'getaround' | 'other'; platform_name: string; name: string; label: string | null; url: string; enabled: boolean;
  status: 'new' | 'ok' | 'error'; last_attempt_at: string | null; last_success_at: string | null; last_error: string | null; failures: number;
  events: number; calendar_name: string | null; upcoming: Array<{ summary: string | null; starts_at: string; ends_at: string; all_day: boolean; blocked: boolean }>;
}
export interface CarRow { id: string; name: string; plate: string | null; is_sample: boolean; turnaround_minutes: number;
  export: { url: string; last_fetched_at: string | null; fetches: number; rotated_at: string | null }; feeds: FeedRow[] }
export interface Conflict { id: string; kind: 'booking' | 'offer'; vehicle: string; platform: string; summary: string | null; starts_at: string; ends_at: string;
  booking_number: string; booking_status: string; pickup_at: string; return_at: string }
export interface SyncData { enabled: boolean; minutes: number; alert_failures: number; turnaround_minutes: number; export_turnaround: boolean; cars: CarRow[]; conflicts: Conflict[]; failing: number }

const at = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' }) : 'never');
const day = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'America/Toronto' });
const span = (s: string, e: string, allDay: boolean) => (allDay ? `${day(s)} to ${day(new Date(new Date(e).getTime() - 1).toISOString())}` : `${at(s)} to ${at(e)}`);
const hours = (m: number) => (m % 60 === 0 ? `${m / 60} hour${m === 60 ? '' : 's'}` : `${m} minutes`);
const PLATFORMS: Array<[FeedRow['platform'], string]> = [['turo', 'Turo'], ['getaround', 'Getaround'], ['other', 'Other']];

function Copy({ url, label, testId }: { url: string; label: string; testId?: string }) {
  const [done, setDone] = useState(false);
  return (
    <div className="cs-copy">
      <label className="small" htmlFor={`cp-${testId}`}>{label}</label>
      <div className="cs-copy__row">
        <input className="input" id={`cp-${testId}`} readOnly value={url} onFocus={(e) => e.currentTarget.select()} data-testid={testId} />
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => { navigator.clipboard?.writeText(url).then(() => setDone(true)).catch(() => setDone(false)); }}>{done ? 'Copied' : 'Copy'}</button>
      </div>
    </div>
  );
}

function Status({ f }: { f: FeedRow }) {
  if (!f.enabled) return <span className="badge badge--grey">Off</span>;
  if (f.status === 'error') return <span className="badge badge--red" data-testid="feed-error">Not working{f.failures > 1 ? ` (${f.failures} tries)` : ''}</span>;
  if (f.status === 'new') return <span className="badge badge--grey">Not read yet</span>;
  return <span className="badge badge--outline" data-testid="feed-ok">Working</span>;
}

function Feed({ f, onDone }: { f: FeedRow; onDone: (msg: string) => void }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const run = (fn: () => Promise<{ ok: boolean; message?: string; data?: unknown }>, msg: string) => start(async () => {
    setErr(null);
    const r = await fn();
    if (!r.ok) setErr(r.message ?? 'That did not work.'); else onDone(msg);
  });
  return (
    <li className="cs-feed" data-testid={`feed-${f.platform}`}>
      <div className="cs-feed__head">
        <b>{f.name}</b> <Status f={f} />
        <span className="small muted">{f.status === 'error' ? `Last good sync ${at(f.last_success_at)}` : `Read ${at(f.last_attempt_at)}`} · {f.events} upcoming</span>
      </div>
      {f.status === 'error' && f.last_error && <p className="small ad-late" role="status">{f.last_error}</p>}
      {f.upcoming.length > 0 && (
        <ul className="cs-events small" aria-label={`Upcoming on ${f.name}`}>
          {f.upcoming.map((e, i) => <li key={i}>{span(e.starts_at, e.ends_at, e.all_day)}: {e.summary || 'Booked'}{e.blocked ? '' : ' (block removed by staff)'}</li>)}
        </ul>
      )}
      <p className="small muted cs-url" title={f.url}>{f.url}</p>
      <div className="row cs-actions">
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} data-testid="feed-sync"
          onClick={() => run(async () => { const r = await calendarSyncNow(f.id); return r.ok && r.data && !r.data.ok ? { ok: false, message: r.data.error } : r; }, 'Synced')}>
          {pending ? 'Working' : 'Sync now'}</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending}
          onClick={() => run(() => calendarAct('calendar_feed_save', { id: f.id, platform: f.platform, label: f.label, url: f.url, enabled: !f.enabled }), f.enabled ? 'Turned off' : 'Turned on')}>
          {f.enabled ? 'Turn off' : 'Turn on'}</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending}
          onClick={() => { if (confirm(`Remove the ${f.name} link? Its trips stop blocking the car.`)) run(() => calendarAct('calendar_feed_remove', { id: f.id }), 'Removed'); }}>Remove</button>
      </div>
      {err && <p className="small ad-late" role="alert">{err}</p>}
    </li>
  );
}

function AddFeed({ car, onDone }: { car: CarRow; onDone: (msg: string) => void }) {
  const [platform, setPlatform] = useState<FeedRow['platform']>('turo');
  const [url, setUrl] = useState('');
  const [label, setLabel] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const id = car.id.slice(0, 8);
  return (
    <form className="cs-add" data-testid="feed-add" onSubmit={(e) => {
      e.preventDefault(); setErr(null);
      start(async () => {
        const r = await calendarAct<{ id: string }>('calendar_feed_add', { vehicle: car.id, platform, url, label });
        if (!r.ok) { setErr(r.message ?? 'That did not work.'); return; }
        const s = r.data ? await calendarSyncNow(r.data.id) : null;
        setUrl(''); setLabel('');
        onDone(s?.ok && s.data?.ok ? `Added and synced: ${s.data.events ?? 0} upcoming` : `Added. ${s?.ok ? s.data?.error ?? '' : s?.message ?? ''}`.trim());
      });
    }}>
      <div className="cs-add__fields">
        <div className="field"><label className="label" htmlFor={`pf-${id}`}>Platform</label>
          <select className="select" id={`pf-${id}`} value={platform} onChange={(e) => setPlatform(e.target.value as FeedRow['platform'])}>{PLATFORMS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <div className="field cs-add__url"><label className="label" htmlFor={`url-${id}`}>Calendar link from the platform</label>
          <input className="input" id={`url-${id}`} type="url" inputMode="url" required placeholder="https://..." value={url} onChange={(e) => setUrl(e.target.value)} data-testid="feed-url" /></div>
        <div className="field"><label className="label" htmlFor={`lb-${id}`}>Name (optional)</label>
          <input className="input" id={`lb-${id}`} maxLength={60} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Turo" /></div>
      </div>
      <button type="submit" className="btn btn--primary btn--sm" disabled={pending || !url.trim()} data-testid="feed-add-submit">{pending ? 'Adding' : 'Add the link'}</button>
      {err && <p className="small ad-late" role="alert">{err}</p>}
    </form>
  );
}

function Car({ car, minutes }: { car: CarRow; minutes: number }) {
  const router = useRouter();
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const done = (m: string) => { setMsg(m); router.refresh(); };
  const base = car.export.url;
  return (
    <section className="pt-card ad-card cs-car" aria-labelledby={`car-${car.id}`} data-testid={`cs-car-${car.id}`}>
      <div className="cs-car__head">
        <h2 className="d4" id={`car-${car.id}`}>{car.name}</h2>
        <span className="small muted">{car.plate ?? 'No plate'}{car.is_sample ? ' · sample car' : ''} · turnaround {hours(car.turnaround_minutes)}</span>
      </div>
      <div className="cs-cols">
        <div>
          <h3 className="cs-h">Blocks from other platforms</h3>
          {car.feeds.length ? <ul className="cs-feeds">{car.feeds.map((f) => <Feed key={f.id} f={f} onDone={done} />)}</ul>
            : <p className="small muted">No calendar link yet. Paste the car&apos;s calendar link from Turo or Getaround: their trips will block it here every {minutes} minutes.</p>}
          <details className="cs-more" open={car.feeds.length === 0 ? undefined : false}>
            <summary className="small">Add a calendar link</summary>
            <AddFeed car={car} onDone={done} />
          </details>
        </div>
        <div>
          <h3 className="cs-h">This car&apos;s CarmaCars calendar</h3>
          <p className="small muted">Paste the link for each platform into that platform&apos;s calendar import. It shows only &quot;Booked&quot; times, nothing about renters.</p>
          <Copy url={`${base}?for=turo`} label="For Turo" testId={`export-turo-${car.id}`} />
          <Copy url={`${base}?for=getaround`} label="For Getaround" testId={`export-getaround-${car.id}`} />
          <Copy url={`${base}?for=other`} label="For any other platform" testId={`export-other-${car.id}`} />
          <p className="small muted">{car.export.fetches ? `Read ${car.export.fetches} times, last ${at(car.export.last_fetched_at)}` : 'Not read by any platform yet'}</p>
          <button type="button" className="btn btn--quiet btn--sm" disabled={pending}
            onClick={() => { if (confirm('Make a new link? The old link stops working: paste the new one into every platform again.')) start(async () => { const r = await calendarAct('calendar_export_rotate', { vehicle: car.id }); done(r.ok ? 'New link made. Paste it into each platform again.' : r.message ?? 'That did not work.'); }); }}>
            Make a new link</button>
        </div>
      </div>
      {msg && <p className="small" role="status" data-testid="cs-msg">{msg}</p>}
    </section>
  );
}

export function CalendarSync({ data, bookingBase }: { data: SyncData; bookingBase: string }) {
  const [q, setQ] = useState('');
  const cars = data.cars.filter((c) => !q || `${c.name} ${c.plate ?? ''}`.toLowerCase().includes(q.toLowerCase()));
  const clashes = data.conflicts.filter((c) => c.kind === 'booking');
  const offers = data.conflicts.filter((c) => c.kind === 'offer');
  return (
    <div className="cs" data-testid="calendar-sync">
      <p className="small muted">{data.enabled ? `Each link is read every ${data.minutes} minutes. A trip from another platform blocks the car with the turnaround before and after it, so it cannot be requested or booked here.` : 'Calendar sync is turned off in Program settings.'}
        {' '}A link that fails {data.alert_failures} times in a row raises a task and an email.</p>
      {clashes.length > 0 && (
        <section className="pt-card ad-card cs-clash" aria-labelledby="cs-clash-h" data-testid="cs-clashes">
          <h2 className="d4" id="cs-clash-h">Double bookings ({clashes.length})</h2>
          <ul className="ad-list">{clashes.map((c) => (
            <li key={c.id}><span><b>{c.vehicle}</b>: {c.platform} {span(c.starts_at, c.ends_at, false)} ({c.summary || 'Booked'}) overlaps <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(c.booking_number)}`}>{c.booking_number}</Link> ({at(c.pickup_at)} to {at(c.return_at)})</span></li>))}</ul>
          <p className="small">Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.</p>
        </section>
      )}
      {offers.length > 0 && (
        <section className="pt-card ad-card" aria-labelledby="cs-off-h">
          <h2 className="d4" id="cs-off-h">Offers over a trip on another platform ({offers.length})</h2>
          <ul className="ad-list">{offers.map((c) => (
            <li key={c.id}><span>{c.vehicle}: <Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(c.booking_number)}`}>{c.booking_number}</Link> ({c.booking_status.replace(/_/g, ' ')}) overlaps {c.platform} {span(c.starts_at, c.ends_at, false)}. Its payment would be refused.</span></li>))}</ul>
        </section>
      )}
      <div className="field cs-find"><label className="label" htmlFor="cs-q">Find a car</label>
        <input className="input" id="cs-q" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Name or plate" /></div>
      {cars.map((c) => <Car key={c.id} car={c} minutes={data.minutes} />)}
      {!cars.length && <p className="ad-empty">No car matches.</p>}
    </div>
  );
}
