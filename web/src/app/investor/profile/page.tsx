import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { door, requireInvestor } from '@/server/door';
import { Requests } from '@/features/investor/Requests';
import { money } from '@/lib/format';
import { auth } from '@/lib/auth';
import { notifyReach } from '@/server/sign-in-settings';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AppProfile } from '@/features/app-shell/AppProfile';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Account', path: '/investor/profile', noindex: true, description: 'Contact details, notices and sign-in.' });

type Home = { investor: { legal_name: string; email: string | null; phone: string | null; address: string | null }; bank_last4: string | null; election_effective_month: string;
  investments: Array<{ id: string; invested_amount_cents: number; investment_date: string }>; documents?: unknown };

// Account (07-investor.md section 2; r27 portals: its file list moved to Documents, Your files, with links): contact
// details read-only, bank account last four, the notices an investor may send, two-step sign-in.
export default async function Profile() {
  const { user } = await requireInvestor('/investor/profile');
  const [h, factors] = await Promise.all([door<Home>(user.id, 'investor_read', 'home'), (await auth()).mfaFactors().catch(() => [])]);
  const nc = await notifyReach(user.id);
  const twoStep = factors.some((f) => f.verified);
  const eff = new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${h.election_effective_month}T12:00:00Z`));
  return (
    <div className="stack">
      <PageHeader title="Account" purpose="Profile and notices: your contact details, how returns are handled, notices you send us, and your sign-in." />
      <section className="pt-card" aria-labelledby="ct-t"><h2 className="d4" id="ct-t">Contact details</h2>
        <dl className="pt-dl"><div><dt>Name</dt><dd>{h.investor.legal_name}</dd></div><div><dt>Email</dt><dd>{h.investor.email ?? ''}</dd></div><div><dt>Phone</dt><dd>{h.investor.phone ?? ''}</dd></div>
          <div><dt>Address</dt><dd>{h.investor.address ?? ''}</dd></div><div><dt>Bank account</dt><dd>{h.bank_last4 ? `ending ${h.bank_last4}` : 'none on file'}</dd></div></dl>
        <p className="small">To update these, ask us; we confirm by phone.</p>
      </section>
      {nc && <NotifyChannelCard reach={nc} />}
      <PushAlerts userId={user.id} portal="investor" />
      <AppProfile userId={user.id} lock />
      <Requests investments={h.investments.map((x) => ({ id: x.id, label: `${money(x.invested_amount_cents, { cents: true })} from ${x.investment_date}` }))} effective={eff} />
      <p className="small muted">Your agreement, schedules and statements are under <Link className="link" href="/investor/documents?tab=files">Documents</Link>.</p>
      <section className="pt-card" aria-labelledby="ts-t" data-testid="two-step-offer"><h2 className="d4" id="ts-t">Two-step sign-in</h2>
        {twoStep ? <p className="small">On: you sign in with your password and a code from your authenticator app.</p>
          : <><p className="small">Add an authenticator app for a second step at sign-in. We recommend it for your investment records.</p><Link className="btn btn--ghost btn--sm" href="/two-step/setup?next=/investor/profile">Set up two-step sign-in</Link></>}</section>
      <AppProfile userId={user.id} deletion />
    </div>
  );
}
