import Link from '@/components/Link';
import './sales-leads.css';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { Filters, MoreFilters, $ } from '@/features/admin/ui';
import { LeadActions, NextLead } from './LeadActions';
import { age, leadHref, stateOf, TYPE_LABEL, STATUS_CHIPS, type LeadList as Data, type LeadRow, type LeadType } from './model';

/** The lead cards (phone-friendly: one column at 375, two or three on wider screens). */
export function LeadCards({ rows, base, admin, people, testId = 'lead-cards' }: { rows: LeadRow[]; base: string; admin: boolean; people: Data['people']; testId?: string }) {
  if (!rows.length) return <p className="small muted" data-testid={`${testId}-empty`}>No leads here.</p>;
  return (
    <ul className="sl-cards" data-testid={testId}>
      {rows.map((r) => (
        <li key={r.id} className={`sl-card pu-panel${r.hot ? ' sl-card--hot' : ''}`} data-testid="lead-card" data-lead={r.id}>
          <div className="sl-card__head">
            <Link prefetch={false} className="link sl-card__name" href={leadHref(base, r.id)}>{r.name ?? r.phone ?? r.email ?? 'No name'}</Link>
            <span className="row" style={{ gap: 'var(--s-1)', flexWrap: 'wrap' }}>
              <span className="badge badge--outline">{TYPE_LABEL[r.type]}</span>
              <span className={`badge ${r.new ? 'badge--red' : 'badge--outline'}`}>{stateOf(r)}</span>
              {r.hot && <span className="badge badge--outline" title="New and not answered yet">Hot</span>}
            </span>
          </div>
          <p className="small sl-card__src"><b data-testid="lead-source">{r.source}</b> · {age(r.created_at)}{r.vehicle ? ` · ${r.vehicle}` : ''}{r.value_cents ? ` · ${$(r.value_cents)}` : ''}</p>
          <p className="small sl-card__contact">{[r.phone, r.email].filter(Boolean).join(' · ') || <span className="muted">No phone or email</span>}</p>
          {r.excerpt && <p className="small muted sl-card__text">{r.excerpt}</p>}
          {r.assigned_name && <p className="small">Assigned to {r.assigned_name}</p>}
          <LeadActions lead={r} admin={admin} people={people} compact />
        </li>))}
    </ul>
  );
}

/** The one Sales lead list (Admin, Sales and customer service; the same on the staff portal): filters, search, priority sort,
 *  Next lead, and the lead cards. `type` fixes the lead type (Owners > Leads). */
export function LeadList({ d, base, listBase, sp, type }: { d: Data; base: string; listBase: string; sp: Record<string, string | undefined>; type?: LeadType }) {
  const page = Math.max(1, Number(sp.page ?? '1') || 1);
  const pages = Math.max(1, Math.ceil(d.count / 50));
  const more = Boolean(sp.source || sp.age || sp.assigned || (!type && sp.type));
  const pageHref = (n: number) => { const q = new URLSearchParams(Object.entries({ ...sp, page: String(n) }).filter(([, v]) => v) as Array<[string, string]>); const [p, own = ''] = listBase.split('?'); for (const [k, v] of new URLSearchParams(own)) q.set(k, v); return `${p}?${q.toString()}`; };
  return (
    <div className="stack" data-testid="sales-leads">
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <p className="small" data-testid="lead-count">{d.count} lead{d.count === 1 ? '' : 's'} · you hold {d.mine_active} of {d.max_active}</p>
        <NextLead base={base} type={type} />
      </div>
      <ListFilters id={`sales-leads${type ? `-${type}` : ''}`} base={listBase} sp={sp} search={{ placeholder: 'Name, phone, email or words' }}
        chips={{ name: 'status', label: 'Status', options: STATUS_CHIPS }}
        sort={{ name: 'sort', label: 'Sort', options: [['', 'Priority'], ['newest', 'Newest'], ['oldest', 'Oldest']] }} kept={['type', 'source', 'age', 'assigned', 'mine']} />
      <MoreFilters active={more}>
        {!type && <Filters base={listBase} name="type" value={sp.type ?? ''} sp={sp} options={[['', 'Every type'], ['renter', 'Renters'], ['owner', 'Owners'], ['partner', 'Partners']]} />}
        <Filters base={listBase} name="source" value={sp.source ?? ''} sp={sp} options={[['', 'Every source'], ...d.sources.map((s): [string, string] => [s.source, `${s.source} (${s.n})`])]} />
        <Filters base={listBase} name="age" value={sp.age ?? ''} sp={sp} options={[['', 'Any age'], ['1', 'Today'], ['7', '7 days'], ['30', '30 days']]} />
        <Filters base={listBase} name="mine" value={sp.mine ?? ''} sp={sp} options={[['', 'Everyone\'s'], ['1', 'Mine']]} />
        {d.admin && <Filters base={listBase} name="assigned" value={sp.assigned ?? ''} sp={sp} options={[['', 'Any person'], ['none', 'Not assigned'], ...d.people.map((p): [string, string] => [p.id, p.name])]} />}
      </MoreFilters>
      <LeadCards rows={d.rows} base={base} admin={d.admin} people={d.people} />
      {pages > 1 && <nav className="row small" style={{ gap: 'var(--s-2)' }} aria-label="Pages">
        {page > 1 && <Link prefetch={false} className="link" href={pageHref(page - 1)}>Newer page</Link>}<span>Page {page} of {pages}</span>
        {page < pages && <Link prefetch={false} className="link" href={pageHref(page + 1)}>Next page</Link>}</nav>}
    </div>
  );
}

/** Renter leads, new first (r35): the open renter leads from every source except the expired offers and the game leads,
 *  which the page shows below, folded. */
export function NewRenterLeads({ d, base, listHref }: { d: Data; base: string; listHref: string }) {
  const rows = d.rows.filter((r) => r.source !== 'Expired offer' && r.source !== 'Discount game claim');
  return (
    <section className="stack" aria-labelledby="nrl-h" data-testid="new-renter-leads">
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <h2 className="d4" id="nrl-h">New leads ({rows.length})</h2>
        <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}><NextLead base={base} type="renter" /><Link prefetch={false} className="btn btn--ghost btn--sm" href={listHref}>Every lead</Link></span>
      </div>
      <LeadCards rows={rows} base={base} admin={d.admin} people={d.people} testId="new-renter-lead-cards" />
    </section>
  );
}
