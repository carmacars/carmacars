import { parseSort, sortRows } from '@/lib/sort';
import { SortSelect } from '@/features/admin/SortTable';
import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { day } from '@/features/owner/Blocks';
import { ONBOARDING_STATUS } from '@/features/owner/types';
import { SendLinkForm } from '@/features/admin/AdminForms';
import { adminOwners, requireAdmin } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { InviteRecordButton, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { ChecklistItems, OwnerChecklist, type OwnerChecklistRow } from '@/features/manual/OwnerChecklist';
import { AddOwnerForm } from '@/features/owner-billing/AddOwnerForm';
import { AgreementsChecklist, openCount, type AgreementOwner } from '@/features/owner-agreements/AgreementsChecklist';
import { SalesLeadsPage } from '@/features/sales-leads/pages';
import { adminCtx } from '@/features/shared-pages/context';

type Acct = { id: string; email: string; name: string; status: string };

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner applications', path: '/admin/owners', noindex: true, description: 'Owner applications.' });

export default async function AdminOwners({ searchParams }: { searchParams: Promise<{ view?: string; show?: string; q?: string; status?: string; sort?: string }> }) {
  const [{ user }, sp] = await Promise.all([requireAdmin('/admin/owners'), searchParams]);
  if (sp.view === 'checklist') return <Checklists userId={user.id} show={sp.show === 'all' ? 'all' : 'open'} />;
  if (sp.view === 'agreements') return <Agreements userId={user.id} show={sp.show === 'all' ? 'all' : 'open'} />;
  // r35 (0950): Owners > Leads, the lead list with owner leads only
  if (sp.view === 'leads') return <SalesLeadsPage ctx={await adminCtx('/admin/owners?view=leads')} sp={sp as Record<string, string | undefined>} base="/admin/sales-leads" listBase="/admin/owners?view=leads" type="owner" title="Owner leads"
    purpose="Owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. Assign them to Sales, claim one, and record the outcome: contacted, call booked, applied, won or lost." />;
  const [every, idx] = await Promise.all([adminOwners(user),
    rpc('admin_account_index', { p_admin: user.id }, { role: 'service_role' }) as unknown as Promise<{ owners: Record<string, Acct> }>]);
  // r32: one search across the name, email and applications; chips for what needs action
  const q = (sp.q ?? '').trim().toLowerCase();
  const rows0 = every.filter((o) => (!q || `${o.legal_name} ${o.email} ${o.applications.join(' ')}`.toLowerCase().includes(q))
    && (sp.status === 'terms' ? o.pending_terms > 0 : sp.status === 'invoices' ? o.invoices_open > 0 : sp.status === 'no_account' ? !idx.owners[o.owner_id] : true));
  // r43: Newest first (by their latest application) unless ?sort= says otherwise
  const rows = sortRows(rows0, parseSort(sp.sort) ?? 'newest', { created: 'last_at', active: 'last_at', name: 'legal_name' });
  return (
    <>
      <PageHead title="Owners" purpose="Every owner with their cars, applications, terms and invoices.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/owners/add-car" data-testid="add-car-for-owner">Add a car for an owner</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/owners?view=agreements" data-testid="owners-agreements">Agreements</Link></PageHead>
      <ListFilters id="admin-owners" base="/admin/owners" sp={sp} search={{ placeholder: 'Name, email or car' }}
        chips={{ name: 'status', label: 'Needs', options: [['', `All (${every.length})`], ['terms', 'Terms to approve'], ['invoices', 'Invoices open'], ['no_account', 'Not invited yet']] }} />
      <div className="ad-sortbar"><SortSelect options={['newest', 'oldest', 'az']} def="newest" /></div>
      <p className="small"><Link prefetch={false} className="link" href="/admin/owners?view=checklist">What each owner has left to pay or sign</Link></p>
      <div className="pt-split">
        <section className="stack" aria-labelledby="ad-list"><h2 className="pt-section-title" id="ad-list">{rows.length} owners</h2>
          {rows.length ? <ul className="ow-rows" data-testid="admin-owners">{rows.map((o) => (
            <li key={o.owner_id}>
              <Link prefetch={false} className="ow-row-link" href={`/admin/owners/${o.owner_id}`}>{o.legal_name}</Link>
              <span className="small">{o.vehicles} vehicle{o.vehicles === 1 ? '' : 's'}</span>
              <span className="ow-meta"><span>{o.applications.join(', ')}</span><span>{day(o.last_at)}</span><span>{o.email}</span>
                {Object.entries(o.statuses ?? {}).map(([s, n]) => <span key={s} className="ad-tag">{n} {ONBOARDING_STATUS[s] ?? s}</span>)}
                {o.pending_terms > 0 && <span className="badge badge--red">{o.pending_terms} terms to approve</span>}
                {o.invoices_open > 0 && <span className="badge badge--outline">{o.invoices_open} invoices open</span>}</span>
              <span className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>{idx.owners[o.owner_id]
                ? (idx.owners[o.owner_id]!.status === 'active' && <><ViewAsButton user={idx.owners[o.owner_id]!.id} portal="owner" testId={`view-as-owner-${o.owner_id}`} /><PasswordLinkButton userId={idx.owners[o.owner_id]!.id} /></>)
                : <InviteRecordButton role="owner" recordId={o.owner_id} email={o.email} name={o.legal_name} testId={`invite-owner-${o.owner_id}`} />}</span>
            </li>))}</ul> : <p className="pt-empty muted">No applications yet.</p>}
        </section>
        <aside className="pt-split__aside stack"><section className="pt-card" aria-labelledby="ad-add-owner"><h2 className="d4" id="ad-add-owner">Add an owner</h2><p className="small muted">On file without a car; add cars later. Nothing is emailed unless you choose to invite.</p><AddOwnerForm /></section>
          <section className="pt-card" aria-labelledby="ad-invite"><h2 className="d4" id="ad-invite">Invite an owner</h2><p className="small muted">Sends a link to the application, valid for 14 days.</p><SendLinkForm kind="invite" /></section></aside>
      </div>
    </>
  );
}

// Every owner's checklist in one place: what is paid and signed, and how, with "Record payment" and "Record paper
// signature" on each owner (migration 0044). Open first; "Show all" lists owners with nothing left too.
async function Checklists({ userId, show }: { userId: string; show: 'open' | 'all' }) {
  const all = await door<OwnerChecklistRow[]>(userId, 'ops_read', 'owner_checklists', {});
  const rows = show === 'all' ? all : all.filter((r) => r.open > 0);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return (
    <>
      <PageHead title="Paid and signed" purpose="What each owner has left to pay or sign.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/owners/add-car">Add a car for an owner</Link></PageHead>
      <p className="small">{all.filter((r) => r.open > 0).length} of {all.length} owners have something left to pay or sign. {show === 'all'
        ? <Link prefetch={false} className="link" href="/admin/owners?view=checklist">Show only those</Link>
        : <Link prefetch={false} className="link" href="/admin/owners?view=checklist&show=all">Show every owner</Link>}</p>
      {rows.length ? <ul className="ow-rows" data-testid="owner-checklists">{rows.map((r) => (
        <li key={r.owner_id} data-owner={r.owner_id}>
          <Link prefetch={false} className="ow-row-link" href={`/admin/owners/${r.owner_id}#checklist`}>{r.legal_name}</Link>
          <span className="ow-meta"><span className={`badge ${r.open ? 'badge--red' : 'badge--outline'}`}>{r.open ? `${r.open} open` : 'All done'}</span><span>{r.done} done</span>{r.paper > 0 && <span>{r.paper} on paper</span>}</span>
          <div style={{ flex: '1 1 100%' }}>
            {r.open > 0
              ? <details><summary className="link small">Checklist and quick actions</summary><OwnerChecklist row={r} signer={r.legal_name} today={today} refresh={['/admin/owners', `/admin/owners/${r.owner_id}`]} /></details>
              : <details><summary className="link small">Checklist</summary><ChecklistItems items={r.items} /></details>}
          </div>
        </li>))}</ul> : <p className="pt-empty muted">Every owner has paid and signed everything.</p>}
    </>
  );
}

// 0640: who still needs to sign. Each owner's required agreements for their deal, sent, signed or missing, with Send.
async function Agreements({ userId, show }: { userId: string; show: 'open' | 'all' }) {
  const all = await door<AgreementOwner[]>(userId, 'ops_read', 'owner_agreements_checklist', {});
  const rows = show === 'all' ? all : all.filter((r) => openCount(r) > 0);
  return (
    <>
      <PageHead title="Agreements" purpose="Each owner's agreements for their deal: signed, sent or still to send.">
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/owners">Owners</Link></PageHead>
      <p className="small">{all.filter((r) => openCount(r) > 0).length} of {all.length} owners have an agreement to sign. {show === 'all'
        ? <Link prefetch={false} className="link" href="/admin/owners?view=agreements">Show only those</Link>
        : <Link prefetch={false} className="link" href="/admin/owners?view=agreements&show=all">Show every owner</Link>}</p>
      <AgreementsChecklist rows={rows} refresh={['/admin/owners']} />
    </>
  );
}
