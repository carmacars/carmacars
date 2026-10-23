import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { Dl } from '@/features/portal/Blocks';
import { ProfileForm } from '@/features/portal/ProfileForm';
import { myProfile, requireUser } from '@/server/portal/data';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/account/profile', noindex: true, description: 'Your contact details, drivers and Card on File.' });

const STATUS: Record<string, string> = { verified: 'Verified', pending: 'In review', unverified: 'Not verified yet', rejected: 'Needs new photos' };

export default async function ProfilePage() {
  const user = await requireUser('/account/profile');
  const [p, si, nc] = await Promise.all([myProfile(user), signInState(user.id), notifyReach(user.id)]);
  const r = p.renter;
  return (
    <>
      <PageHeader title="Profile" purpose="Your details, sign-in, card on file and drivers." />
      <div className="pt-split">
        <div className="stack-lg">
          <section className="pt-card" aria-labelledby="pt-me"><h2 className="d4" id="pt-me">You</h2>
            <Dl rows={[['Legal name', r?.legal_name ?? p.user?.full_name ?? ''], ['Email', p.user?.email ?? user.email ?? ''], ['Identity', r ? STATUS[r.identity_status] ?? r.identity_status : '']]} />
            <p className="small muted">Your legal name is locked once you are verified. To change it or your email, call or message us.</p>
          </section>
          {si && <SignInSettings state={si} />}
          {nc && <NotifyChannelCard reach={nc} />}
          <section className="pt-card" aria-labelledby="pt-contact"><h2 className="d4" id="pt-contact">Contact details</h2>
            {r ? <ProfileForm initial={{ mobile: r.mobile ?? p.user?.phone ?? '', address_line1: r.address_line1 ?? '', address_line2: r.address_line2 ?? '', city: r.city ?? '', province: r.province ?? '', postal_code: r.postal_code ?? '', country: r.country ?? 'Canada' }} />
              : <p className="muted">Your contact details are saved with your first booking request.</p>}
          </section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="pt-card"><h2 className="d4" id="pt-card">Card on File</h2>
            {p.cards.length ? <Dl rows={p.cards.map((c) => [`${c.brand.toUpperCase()} ending ${c.last4}`, `Expires ${String(c.exp_month).padStart(2, '0')}/${c.exp_year}`])} /> : <p className="muted small">Saved when you pay for your first booking.</p>}
          </section>
          <section className="pt-card" aria-labelledby="pt-drv"><h2 className="d4" id="pt-drv">Drivers</h2>
            {p.drivers.length ? <Dl rows={p.drivers.map((d) => [d.full_name, `${d.is_account_holder ? 'You' : 'Additional driver'}, ${STATUS[d.identity_status] ?? d.identity_status}`])} /> : <p className="muted small">None yet.</p>}
          </section>
        </aside>
      </div>
    </>
  );
}
