import Link from '@/components/Link';
import './sales-leads.css';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { $ } from '@/features/admin/ui';
import { LeadActions, NextLead } from './LeadActions';
import { ClaimPace } from './ClaimPace';
import { age, bulkFilter, holdWords, leadHref, stateOf, TYPE_LABEL, STATUS_CHIPS, type LeadList as Data, type LeadRow, type LeadType } from './model';
import { BulkAssign, BULK_FORM } from './BulkAssign';
import { RenterToggle } from './RenterToggle';

/** The lead cards (phone-friendly: one column at 375, two or three on wider screens). */
export function LeadCards({ rows, base, admin, people, testId = 'lead-cards', pick = false }: { rows: LeadRow[]; base: string; admin: boolean; people: Data['people']; testId?: string; /** 2411: a tick box for the bulk bar */ pick?: boolean }) {
  const portal = base.startsWith('/admin') ? '/admin' : '/staff';
  if (!rows.length) return <p className="small muted" data-testid={`${testId}-empty`}>No leads here.</p>;
  return (
    <ul className="sl-cards" data-testid={testId}>
      {rows.map((r) => (
        <li key={r.id} className={`sl-card pu-panel${r.hot ? ' sl-card--hot' : ''}`} data-testid="lead-card" data-lead={r.id}>
          <div className="sl-card__head">
            <span className="row" style={{ gap: 'var(--s-1)', minWidth: 0 }}>
              {pick && <label className="sl-pick"><input type="checkbox" form={BULK_FORM} name="ids" value={r.id} data-testid="lead-pick" /><span className="vh">Choose {r.name ?? 'this lead'}</span></label>}
              <Link prefetch={false} className="link sl-card__name" href={leadHref(base, r.id)}>{r.name ?? r.phone ?? r.email ?? 'No name'}</Link>
            </span>
            <span className="row" style={{ gap: 'var(--s-1)', flexWrap: 'wrap' }}>
              <span className="badge badge--outline">{TYPE_LABEL[r.type]}</span>
              <span className={`badge ${r.new ? 'badge--red' : 'badge--outline'}`}>{stateOf(r)}</span>
              {r.hot && <span className="badge badge--outline" title="New and not answered yet">Hot</span>}
            </span>
          </div>
          <p className="small sl-card__src"><b data-testid="lead-source">{r.source}</b> · {age(r.created_at)}{r.vehicle ? ` · ${r.vehicle}` : ''}{r.value_cents ? ` · ${$(r.value_cents)}` : ''}</p>
          <p className="small sl-card__contact">{[r.phone, r.email].filter(Boolean).join(' · ') || <span className="muted">No phone or email</span>}</p>
          {r.excerpt && <p className="small muted sl-card__text">{r.excerpt}</p>}
          {holdWords(r.hold).text && <p className="small" data-testid="lead-hold">{holdWords(r.hold).text}</p>}
          {r.assigned_name && <p className="small" data-testid="lead-assigned">Assigned to {r.assigned_name}{r.admin_assigned ? ' by an Admin' : ''}</p>}
          <LeadActions lead={r} admin={admin} people={people} compact />
          <RenterToggle lead={r.id} portal={portal} />
        </li>))}
    </ul>
  );
}

/** The one Sales lead list (Admin, Sales and customer service; the same on the staff portal): filters, search, priority sort,
 *  Next lead, and the lead cards. `type` fixes the lead type (Owners > Leads). */
export function LeadList({ d, base, listBase, sp, type }: { d: Data; base: string; listBase: string; sp: Record<string, string | undefined>; type?: LeadType }) {
  const page = Math.max(1, Number(sp.page ?? '1') || 1);
  const pages = Math.max(1, Math.ceil(d.count / 50));
  const pageHref = (n: number) => { const q = new URLSearchParams(Object.entries({ ...sp, page: String(n) }).filter(([, v]) => v) as Array<[string, string]>); const [p, own = ''] = listBase.split('?'); for (const [k, v] of new URLSearchParams(own)) q.set(k, v); return `${p}?${q.toString()}`; };
  return (
    <div className="stack" data-testid="sales-leads">
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <p className="small" data-testid="lead-count">{d.count} lead{d.count === 1 ? '' : 's'} · <ClaimPace held={d.mine_active} max={d.max_active} nextAt={d.next_claim_at ?? null} cooldown={d.claim_cooldown_minutes ?? 0} paced={d.paced ?? !d.admin} winsToNext={d.cap?.wins_to_next ?? null} /></p>
        <NextLead base={base} type={type} />
      </div>
      <ListFilters id={`sales-leads${type ? `-${type}` : ''}`} base={listBase} sp={sp} search={{ placeholder: 'Name, phone, email or words' }}
        chips={{ name: 'status', label: 'Status', options: STATUS_CHIPS }}
        sort={{ name: 'sort', label: 'Sort', options: [['', 'Priority'], ['newest', 'Newest'], ['oldest', 'Oldest']] }} kept={['type', 'source', 'age', 'assigned', 'mine']} />
      {d.admin && <BulkAssign people={d.assignees ?? []} filter={bulkFilter(sp, type)} count={d.count} />}
      <LeadCards rows={d.rows} base={base} admin={d.admin} people={d.people} pick={d.admin} />
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
