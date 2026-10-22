import { cookies } from 'next/headers';
import { Crumbs } from '@/components/Crumbs';
import { pageMeta, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { ApplyWizard, type ProgramFacts } from '@/features/owner/ApplyWizard';
import { blankOwner, DRAFT_COOKIE, type ApplyState } from '@/features/owner/apply-schema';
import { currentUser } from '@/server/portal/data';
import { ownerHome } from '@/server/owner/data';
import { readToken } from '@/server/links';
import '@/styles/portal.css';
import '@/styles/owner.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Apply to list your car', path: '/list-your-car/apply', noindex: true, description: 'Enrol one or more vehicles in the CarmaCars owner program: about you, your vehicles, how each will work, and the costs to start.' });
const trail: Trail = [['Home', '/'], ['List your car', '/list-your-car'], ['Apply']];
const SR = { role: 'service_role' as const };

// The owner application (public entry from "List your car" and from an invitation link). The draft
// comes back from form_drafts: the account's when signed in, otherwise the device's (a cookie token).
export default async function Apply({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const user = await currentUser();
  const token = (await cookies()).get(DRAFT_COOKIE)?.value;
  // a visitor who signs in part way keeps the answers saved on this device
  const loadDraft = async () => {
    const mine = user ? await rpc('load_form_draft', { p_form_code: 'owner_application', p_user: user.id }, SR).catch(() => null) : null;
    return (mine ?? (token ? await rpc('load_form_draft', { p_form_code: 'owner_application', p_token: token }, SR).catch(() => null) : null)) as unknown as { data: ApplyState } | null;
  };
  const [facts, draft, home, invite] = await Promise.all([
    rpc('server_owner_program_facts', {}, SR) as unknown as Promise<ProgramFacts>,
    loadDraft(),
    user ? ownerHome(user).catch(() => null) : Promise.resolve(null),
    readToken<{ e: string; n: string }>('owner-invite', sp.invite ?? null)
  ]);
  const owner = { ...blankOwner(), ...(draft?.data?.owner ?? {}) };
  if (home) {
    const o = home.owner;
    Object.assign(owner, { owner_type: owner.owner_type || o.owner_type, first_name: owner.first_name || o.first_name, last_name: owner.last_name || o.legal_name.split(' ').slice(1).join(' '),
      corporation_name: owner.corporation_name || o.corporation_name || '', corporation_number: owner.corporation_number || o.corporation_number || '', signing_officer_title: owner.signing_officer_title || o.signing_officer_title || '',
      address_line1: owner.address_line1 || o.address_line1 || '', city: owner.city || o.city || '', province: owner.province || o.province || 'ON', postal_code: owner.postal_code || o.postal_code || '',
      email: owner.email || o.email || '', phone: owner.phone || o.phone || '', hst_number: owner.hst_number || o.hst_number || '' });
  }
  if (!owner.email && user) owner.email = user.email;
  if (invite) {
    owner.email ||= invite.e;
    const [first, ...rest] = invite.n.split(' ');
    owner.first_name ||= first ?? '';
    owner.last_name ||= rest.join(' ');
  }
  const initial: ApplyState = { step: Math.min(3, Math.max(0, draft?.data?.step ?? 0)), owner, vehicles: draft?.data?.vehicles ?? [], active: draft?.data?.vehicles?.length ? -1 : 0 };
  // a draft with no car starts at step 1: an owner whose account opened without a car (an autosave can land after the
  // account is open) comes back to add one, not to the review of the account they already have
  if (initial.step > 0 && !initial.vehicles.length) initial.step = 0;
  return (
    <div className="ow-apply">
      <div className="wrap ow-apply__inner">
        <Crumbs trail={trail} />
        <header className="stack">
          <h1 className="d2">Apply to list your car</h1>
          <p className="muted">About 10 minutes. Have your ownership permit and driver&apos;s licence at hand. Add every vehicle you want to enrol; we reply within 1 business day with the terms for each.</p>
          {draft && <p className="pt-note" data-testid="resumed">Welcome back. Your answers were saved{draft.data?.vehicles?.length ? `, with ${draft.data.vehicles.length} vehicle${draft.data.vehicles.length === 1 ? '' : 's'}` : ''}.</p>}
          {sp.expired && <p className="alert alert--error" role="alert"><span>That link has expired or was already used. Start here, or ask for a new link.</span></p>}
        </header>
        <ApplyWizard initial={initial} facts={facts} signedIn={!!user} ownerOnFile={!!home} />
      </div>
    </div>
  );
}
