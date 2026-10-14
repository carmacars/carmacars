import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { day } from '@/features/owner/Blocks';
import { ONBOARDING_STATUS } from '@/features/owner/types';
import { SendLinkForm } from '@/features/admin/AdminForms';
import { adminOwners, requireAdmin } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { InviteRecordButton, PasswordLinkButton } from '@/features/admin/AccountTools';
import { ViewAsButton } from '@/features/admin/ViewAs';

type Acct = { id: string; email: string; name: string; status: string };

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner applications', path: '/admin/owners', noindex: true, description: 'Owner applications.' });

export default async function AdminOwners() {
  const { user } = await requireAdmin('/admin/owners');
  const [rows, idx] = await Promise.all([adminOwners(user),
    rpc('admin_account_index', { p_admin: user.id }, { role: 'service_role' }) as unknown as Promise<{ owners: Record<string, Acct> }>]);
  return (
    <>
      <h1 className="d2">Owner applications</h1>
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
        <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="ad-invite"><h2 className="d4" id="ad-invite">Invite an owner</h2><p className="small muted">Sends a link to the application, valid for 14 days.</p><SendLinkForm kind="invite" /></section></aside>
      </div>
    </>
  );
}
