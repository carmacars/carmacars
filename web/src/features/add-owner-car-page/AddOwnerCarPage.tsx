import Link from '@/components/Link';
import { PageHead } from '@/features/admin/ui';
import { AddOwnerCar } from '@/features/owner-billing/AddOwnerCar';
import type { PageCtx } from '@/features/shared-pages/context';
import { portalBase } from '@/features/shared-pages/viewer';

// r31 "Simple": one Add a car for an owner page (migration 0067) for Admin and staff. An Admin's car goes straight to the
// owner; customer service and Fleet propose the terms and first invoices for an Admin to approve; Sales start a new
// owner's application (0340): the same form with the permit reader, without the terms, credited to them.
export async function AddOwnerCarPage({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  const { viewer, read, ops } = ctx;
  const admin = viewer.role === 'admin';
  const base = portalBase(viewer);
  if (viewer.role === 'staff' && viewer.fn === 'sales') {
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
    return (
      <>
        <PageHead title="Start an owner's application" />
        <p className="small muted" style={{ maxWidth: '48rem' }}>Enter the owner and their car. It goes to an Admin as an application to approve, credited to you; the owner then gets one email to review and sign.</p>
        <div style={{ maxWidth: '60rem' }}><AddOwnerCar initial={{ admin: false, today, hst_bps: 1300, trackers_available: false, owner: null, terms: null, standard: null }} base="/staff" sales /></div>
      </>
    );
  }
  const owner = /^[0-9a-f-]{36}$/.test(sp.owner ?? '') ? sp.owner! : null;
  type Facts = Parameters<typeof AddOwnerCar>[0]['initial'];
  const facts = admin ? await ops<Facts>('owner_add_car_facts', { owner_id: owner }) : await read<Facts>('owner_add_car_facts', { owner_id: owner });
  return (
    <>
      {admin
        ? <PageHead kicker={<Link prefetch={false} className="link" href={owner ? `/admin/owners/${owner}` : '/admin/owners'}>{facts.owner ? facts.owner.legal_name : 'Owners'}</Link>} title={facts.owner ? 'Add another car' : 'Add a car for an owner'} />
        : <PageHead title={facts.owner ? `Add another car for ${facts.owner.legal_name}` : 'Add a car for an owner'} />}
      <p className="small muted" style={{ maxWidth: '48rem' }}>{admin
        ? 'Everything the owner would enter in their application, entered for them. The owner gets one email to review the details, correct anything and sign; or they sign on paper and you record it.'
        : 'Enter everything for the owner. An Admin checks the terms and first invoice, then approves; the owner gets one email to review and sign.'}</p>
      <div style={{ maxWidth: '60rem' }}><AddOwnerCar initial={facts} base={base} /></div>
    </>
  );
}
