import Link from '@/components/Link';
import { activeCount, hrefWith, MAX_CHIPS, type Group, type Opt } from './model';
import { RememberFilters } from './RememberFilters';

// r32 "Simple": the one filter bar of every list: one search box (it matches across fields: the list's own search), one
// row of at most 5 chips (statuses that need action), at most one date range where dates matter, and one sort with 2 or 3
// options. Nothing else: a filter that did not fit is served by the search or reached as a link (a saved view). Old
// parameters a list still honours (`kept`) are cleared with Clear. The last choice is remembered on this device.
export function ListFilters({ id, base, sp, search, chips, dates, sort, kept = [], testId = 'list-filters' }: {
  id: string; base: string; sp: Record<string, string | undefined>;
  search?: { placeholder: string; action?: string };
  chips?: Group;
  /** a date range (only where dates matter: bookings, money) */
  dates?: { from: string; to: string; label: string };
  /** one sort, 2 or 3 options, newest first by default */
  sort?: Group;
  /** old parameters the list still reads (links from other pages): kept in the search form and cleared by Clear */
  kept?: string[];
  testId?: string;
}) {
  const names = [chips?.name, sort?.name, dates?.from, dates?.to, ...kept].filter(Boolean) as string[];
  const used = activeCount(sp, names);
  const link = (g: Group, [v, l]: Opt) => <Link prefetch={false} scroll={false} key={v || 'all'} href={hrefWith(base, sp, g.name, v)} aria-current={(sp[g.name] ?? '') === v ? 'page' : undefined}>{l}</Link>;
  const action = search?.action ?? base.split('?')[0]!;
  return (
    <section className="lf" aria-label="Find and filter" data-testid={testId}>
      <RememberFilters id={id} names={names} />
      {(search || dates) && (
        <form className="ad-search lf__search" action={action} role="search">
          {[...new URLSearchParams(base.split('?')[1] ?? '')].map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          {names.filter((n) => sp[n] && n !== dates?.from && n !== dates?.to).map((n) => <input key={n} type="hidden" name={n} value={sp[n]} />)}
          {search && <><label className="vh" htmlFor={`${id}-q`}>{search.placeholder}</label>
            <input className="input" id={`${id}-q`} name="q" type="search" defaultValue={sp.q} placeholder={search.placeholder} data-shortcut="/" /></>}
          {dates && <span className="lf__dates"><span className="small">{dates.label}</span>
            <label className="vh" htmlFor={`${id}-from`}>From</label><input className="input" id={`${id}-from`} name={dates.from} type="date" defaultValue={sp[dates.from]} />
            <label className="vh" htmlFor={`${id}-to`}>To</label><input className="input" id={`${id}-to`} name={dates.to} type="date" defaultValue={sp[dates.to]} /></span>}
          <button className="btn btn--ghost btn--sm" type="submit">{search ? 'Search' : 'Show'}</button>
        </form>
      )}
      {chips && <nav className="ad-filters lf__chips" aria-label={chips.label} data-testid={`${testId}-chips`}>{chips.options.slice(0, MAX_CHIPS).map((o) => link(chips, o))}</nav>}
      {sort && <nav className="ad-filters lf__sort" aria-label={sort.label}><span className="small muted">{sort.label}</span>{sort.options.slice(0, 3).map((o) => link(sort, o))}</nav>}
      {(used > 0 || sp.q) && <Link prefetch={false} className="link small lf__clear" href={`${base}${base.includes('?') ? '&' : '?'}clear=1`} data-testid={`${testId}-clear`}>Clear</Link>}
    </section>
  );
}
