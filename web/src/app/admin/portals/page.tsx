import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { requireAdmin } from '@/server/admin/data';
import { Card, PageHead, Search, Table } from '@/features/admin/ui';
import { ViewAsButton, ViewAsPicker, type Portal } from '@/features/admin/ViewAs';
import { InviteForm, PasswordLinkButton } from '@/features/admin/AccountTools';
import { FN_NAME } from '@/server/portals';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Portals and sign-in', path: '/admin/portals', noindex: true, description: 'Every portal, who can sign in to it, and view as.' });

interface Person { id: string; email: string; name: string; status: string; portals: { admin: boolean; va_functions: string[]; field: boolean; owner: boolean; investor: boolean; renter: boolean } }
interface People { limit: number; people: Person[]; owners_without_account: Array<{ id: string; name: string; email: string | null }>; investors_without_account: Array<{ id: string; name: string; email: string | null }> }

// Admin > Portals: each portal with its real sign-in and "Open as" one of its people (read only, with the red
// banner, recorded in the audit log), everyone who can sign in with the portals they have, and invitations.
export default async function Portals({ searchParams }: { searchParams: Promise<{ q?: string; error?: string }> }) {
  const { user } = await requireAdmin('/admin/portals');
  const { q, error } = await searchParams;
  const d = (await rpc('admin_portal_people', { p_admin: user.id, p_q: q || undefined, p_limit: 300 }, { role: 'service_role' })) as unknown as People;
  const active = d.people.filter((p) => p.status === 'active' && p.id !== user.id);
  const who = (f: (p: Person) => boolean) => active.filter(f).map((p) => ({ id: p.id, name: p.name, email: p.email }));
  const sections: Array<{ key: string; title: string; home: string; portal: Portal | null; fn?: string; people: ReturnType<typeof who> }> = [
    { key: 'admin', title: 'Admin', home: '/admin', portal: null, people: [] },
    ...['finance', 'fleet', 'cs', 'sales'].map((fn) => ({ key: `va-${fn}`, title: `Staff portal: ${FN_NAME[fn]}`, home: '/va', portal: 'va' as Portal, fn, people: who((p) => p.portals.va_functions.includes(fn)) })),
    { key: 'field', title: 'Field portal', home: '/field', portal: 'field', people: who((p) => p.portals.field) },
    { key: 'owner', title: 'Owner portal', home: '/owner', portal: 'owner', people: who((p) => p.portals.owner) },
    { key: 'investor', title: 'Investor portal', home: '/investor', portal: 'investor', people: who((p) => p.portals.investor) },
    { key: 'account', title: 'Renter portal (My rentals)', home: '/account', portal: 'account', people: who((p) => p.portals.renter) }
  ];
  const badges = (p: Person) => [p.portals.admin && 'Admin', ...p.portals.va_functions.map((f) => `Staff: ${FN_NAME[f] ?? f}`), p.portals.field && 'Field', p.portals.owner && 'Owner', p.portals.investor && 'Investor', p.portals.renter && 'Renter'].filter(Boolean) as string[];
  return (<>
    <PageHead title="Portals and sign-in" kicker="People" />
    {error && <p className="alert alert--error" role="alert" data-testid="portals-error"><span>{error}</span></p>}
    <p className="muted">Open any portal as one of its people to see exactly what they see. It is read only: nothing can be changed while viewing, a red banner shows whose view it is, and every view is recorded in the audit log. It ends after 30 minutes, or with Exit.</p>
    <div className="ad-cols ad-cols--3" data-testid="portal-list">
      {sections.map((s) => (
        <Card key={s.key} title={s.title} testId={`portal-${s.key}`} aside={<Link prefetch={false} className="link small" href={`/sign-in?next=${encodeURIComponent(s.home)}`}>Its sign-in page</Link>}>
          {s.portal ? <ViewAsPicker id={`va-pick-${s.key}`} portal={s.portal} fn={s.fn} people={s.people} testId={`open-as-${s.key}`} />
            : <p className="small">You are an Admin: <Link prefetch={false} className="link" href="/admin">open Admin</Link>.</p>}
          {s.portal && !s.people.length && <p className="small"><a className="link" href="#invite">Invite someone</a></p>}
        </Card>))}
    </div>
    <Card title="Invite a person" id="invite" testId="invite-card">
      <p className="small muted">They get the CarmaCars invitation email with a link to choose a password (it works for 24 hours), then land in their portal. Someone who already signs in just gets the new role.</p>
      <InviteForm owners={d.owners_without_account.map((o) => ({ ...o, email: o.email }))} investors={d.investors_without_account.map((o) => ({ ...o, email: o.email }))} />
    </Card>
    <Card title={`People who can sign in${q ? `: "${q}"` : ''}`} aside={<Search action="/admin/portals" value={q} placeholder="Name or email" />}>
      {d.people.length >= d.limit && <p className="small muted">Showing the first {d.limit}: staff, then owners and investors, then renters. Search by name or email to find anyone else; the pickers above follow the search.</p>}
      <Table<Person & Record<string, unknown>> testId="portal-people" rows={d.people as Array<Person & Record<string, unknown>>} empty="No one matches. Search by name or email, or invite the person below." cols={[
        { key: 'name', label: 'Name' }, { key: 'email', label: 'Email' },
        { key: 'portals', label: 'Portals', render: (p) => badges(p).join(', ') || 'None' },
        { key: 'status', label: 'Status' },
        { key: 'actions', label: '', render: (p) => p.id === user.id ? <span className="small muted">You</span> : p.status !== 'active' ? <span className="small muted">Access ended</span> : (
          <span className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
            <PasswordLinkButton userId={p.id} testId={`pw-${p.email}`} />
            {p.portals.va_functions.map((f) => <ViewAsButton key={f} user={p.id} portal="va" fn={f} label={`View as (${FN_NAME[f] ?? f})`} />)}
            {p.portals.field && <ViewAsButton user={p.id} portal="field" />}
            {p.portals.owner && <ViewAsButton user={p.id} portal="owner" />}
            {p.portals.investor && <ViewAsButton user={p.id} portal="investor" />}
            {p.portals.renter && <ViewAsButton user={p.id} portal="account" />}
          </span>) }]} />
    </Card>
  </>);
}
