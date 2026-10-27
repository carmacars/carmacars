import Link from 'next/link';
import type { ReactNode } from 'react';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

// The admin portal's server-rendered pieces: dense tables, tabs, tiles, badges. Same tokens as the
// portals (portal.css, owner.css, admin.css); money and times exactly as the database stored them.
export type Col<T> = { key: string; label: string; num?: boolean; render?: (r: T) => ReactNode; className?: string };

export function Table<T extends Record<string, unknown>>({ cols, rows, empty = 'Nothing here yet.', caption, rowKey, testId }: {
  cols: Array<Col<T>>; rows: T[]; empty?: string; caption?: string; rowKey?: (r: T, i: number) => string; testId?: string;
}) {
  if (!rows.length) return <p className="ad-empty" data-testid={testId ? `${testId}-empty` : undefined}>{empty}</p>;
  return (
    <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label={caption ?? 'Table'}>
      {/* on a phone each row is a card with its column names (admin.css, .ad-table--cards); the roles keep it a table */}
      <table className="ad-table ad-table--dense ad-table--cards" role="table" data-testid={testId}>
        {caption && <caption className="vh">{caption}</caption>}
        <thead role="rowgroup"><tr role="row">{cols.map((c) => <th key={c.key} role="columnheader" scope="col" className={c.num ? 'num' : undefined}>{c.label}</th>)}</tr></thead>
        <tbody role="rowgroup">{rows.map((r, i) => (
          <tr key={rowKey ? rowKey(r, i) : String(r.id ?? i)} role="row">
            {cols.map((c) => <td key={c.key} role="cell" data-label={c.label} className={[c.num ? 'num' : '', c.className ?? ''].join(' ').trim() || undefined}>{c.render ? c.render(r) : fmt(r[c.key])}</td>)}
          </tr>))}
        </tbody>
      </table>
    </div>
  );
}

export function fmt(v: unknown): ReactNode {
  if (v === null || v === undefined || v === '') return <span className="muted">none</span>;
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v)) return when(v);
  if (typeof v === 'object') return <span className="pt-mono">{JSON.stringify(v)}</span>;
  return String(v);
}

export const $ = (c: unknown) => (c === null || c === undefined ? '' : money(Number(c), { cents: true }));
export const t = (iso: unknown) => (typeof iso === 'string' ? when(iso) : '');
export const d = (iso: unknown) => (typeof iso === 'string' ? when(iso.length === 10 ? `${iso}T12:00:00Z` : iso, false) : '');
export const label = (s: unknown) => (typeof s === 'string' ? s.replace(/_/g, ' ') : '');
export const ago = (min: number) => (min < 60 ? `${min} min` : min < 1440 ? `${Math.floor(min / 60)} h ${min % 60} min` : `${Math.floor(min / 1440)} d ${Math.floor((min % 1440) / 60)} h`);

const TONE: Record<string, string> = {
  requested: 'ad-b--wait', offered: 'ad-b--amber', pending_payment: 'ad-b--amber', confirmed: 'ad-b--dark', on_rent: 'ad-b--red',
  returned: 'ad-b--grey', closed: 'ad-b--light', cancelled: 'ad-b--light', expired: 'ad-b--light', declined: 'ad-b--light', no_show: 'ad-b--light',
  failed: 'ad-b--red', succeeded: 'ad-b--dark', paid: 'ad-b--dark', approved: 'ad-b--dark', draft: 'ad-b--wait', sent: 'ad-b--amber',
  pending_approval: 'ad-b--amber', awaiting_signature: 'ad-b--amber', published: 'ad-b--dark', needs_review: 'ad-b--amber', open: 'ad-b--wait', done: 'ad-b--light', hidden: 'ad-b--light'
};
export function Badge({ s, children }: { s: string; children?: ReactNode }) {
  const text = label(s);
  return <span className={`ad-b ${TONE[s] ?? ''}`} data-status={s}>{children ?? (text.charAt(0).toUpperCase() + text.slice(1))}</span>;
}

export function Tabs({ items, current, label: aria = 'Sections' }: { items: Array<[string, string, number?]>; current: string; label?: string }) {
  return (
    <nav className="ad-tabs" aria-label={aria}>
      {items.map(([href, text, n]) => (
        <Link prefetch={false} key={href} href={href} aria-current={href === current ? 'page' : undefined}>{text}{n ? <span className="pt__count">{n}</span> : null}</Link>
      ))}
    </nav>
  );
}

export function Tiles({ items }: { items: Array<{ k: string; v: ReactNode; sub?: ReactNode; href?: string; warn?: boolean }> }) {
  return (
    <div className="ad-tiles">
      {items.map((i) => {
        const body = <><span className="ad-tile__k">{i.k}</span><b className="ad-tile__v">{i.v}</b>{i.sub ? <span className="ad-tile__s">{i.sub}</span> : null}</>;
        return i.href ? <Link prefetch={false} key={i.k} href={i.href} className={`ad-tile${i.warn ? ' is-warn' : ''}`}>{body}</Link> : <div key={i.k} className={`ad-tile${i.warn ? ' is-warn' : ''}`}>{body}</div>;
      })}
    </div>
  );
}

export function Card({ title, children, aside, id, testId, tone }: { title: ReactNode; children: ReactNode; aside?: ReactNode; id?: string; testId?: string; tone?: 'next' | 'warn' }) {
  const hid = id ?? (typeof title === 'string' ? `c-${title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}` : undefined);
  return (
    <section className={`pt-card ad-card${tone === 'next' ? ' pt-card--next' : tone === 'warn' ? ' ad-card--warn' : ''}`} aria-labelledby={hid} data-testid={testId}>
      <div className="pt-card__head"><h2 className="d4" id={hid}>{title}</h2>{aside}</div>
      {children}
    </section>
  );
}

/** The page header: kicker, title, what the page is for in one line (purpose), then the page's actions. */
export function PageHead({ title, kicker, purpose, children }: { title: ReactNode; kicker?: ReactNode; purpose?: ReactNode; children?: ReactNode }) {
  return (
    <header className="ad-head">
      <div className="ad-head__text">{kicker && <p className="pt-kicker">{kicker}</p>}<h1 className="d3">{title}</h1>{purpose && <p className="small muted ad-head__purpose">{purpose}</p>}</div>
      {children && <div className="ad-head__actions">{children}</div>}
    </header>
  );
}

export function Kv({ rows }: { rows: Array<[string, ReactNode]> }) {
  return <dl className="pt-dl ad-kv">{rows.filter(([, v]) => v !== null && v !== undefined && v !== '').map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>;
}

export const bookingHref = (n: unknown) => `/admin/bookings/${encodeURIComponent(String(n))}`;
export function BookingLink({ n }: { n: unknown }) {
  return n ? <Link prefetch={false} className="link" href={bookingHref(n)}>{String(n)}</Link> : <span className="muted">none</span>;
}

/** Filter links that keep the rest of the query string. */
export function Filters({ base, name, value, options, sp }: { base: string; name: string; value: string; options: Array<[string, string]>; sp?: Record<string, string | undefined> }) {
  const href = (v: string) => {
    // a base may carry its own query (?tab=...): merged, never appended as a second "?" (the hiring filters, 0173)
    const [path = base, own = ''] = base.split('?');
    const q = new URLSearchParams(Object.entries(sp ?? {}).filter(([k, x]) => k !== name && x) as Array<[string, string]>);
    for (const [k, x] of new URLSearchParams(own)) q.set(k, x);
    if (v) q.set(name, v);
    const s = q.toString();
    return s ? `${path}?${s}` : path;
  };
  return (
    <nav className="ad-filters" aria-label={`Filter by ${name.replace(/_/g, ' ')}`}>
      {options.map(([v, l]) => <Link prefetch={false} key={v || 'all'} href={href(v)} aria-current={value === v ? 'page' : undefined}>{l}</Link>)}
    </nav>
  );
}

export function Search({ action, value, placeholder = 'Search' }: { action: string; value?: string; placeholder?: string }) {
  return (
    <form className="ad-search" action={action} role="search">
      <label className="vh" htmlFor="ad-q">{placeholder}</label>
      <input className="input" id="ad-q" name="q" type="search" defaultValue={value} placeholder={placeholder} data-shortcut="/" />
      <button className="btn btn--ghost btn--sm" type="submit">Search</button>
    </form>
  );
}

/** Filters past the first row, folded (portal cleanup, October 23, 2026): open by itself when one of them is in use. */
export function MoreFilters({ active, children, label: text = 'More filters' }: { active: boolean; children: ReactNode; label?: string }) {
  return <details className="ad-morefilters" open={active} data-testid="more-filters"><summary>{text}{active ? ' (in use)' : ''}</summary><div>{children}</div></details>;
}
