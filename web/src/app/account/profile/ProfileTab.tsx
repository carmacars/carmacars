import { Dl } from '@/features/portal/Blocks';
import { ProfileForm } from '@/features/portal/ProfileForm';
import { myProfile } from '@/server/portal/data';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { selfProfile } from '@/server/self-profile';
import { SelfProfile } from '@/features/portal/SelfProfile';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AppProfile } from '@/features/app-shell/AppProfile';
import type { SessionUser } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import { SecondaryContactForm, type ContactValue } from '@/features/portal/SecondaryContactForm';

const STATUS: Record<string, string> = { verified: 'Verified', pending: 'In review', unverified: 'Not verified yet', rejected: 'Needs new photos' };

// Account > Profile: who you are, how you sign in, your contact details, card on file and drivers.
export async function ProfileTab({ user }: { user: SessionUser }) {
  const [p, si, nc, sp, sc] = await Promise.all([myProfile(user), signInState(user.id), notifyReach(user.id), selfProfile(user.id),
    // r35a (1302): the optional secondary contact
    rpc('server_secondary_contact', { p_by: user.id }, { role: 'service_role' }).then((x) => (x as unknown as { profile: ContactValue | null }).profile).catch(() => null)]);
  const r = p.renter;
  return (
    <div className="pt-split">
      <div className="stack-lg">
        <section className="pt-card" aria-labelledby="pt-me"><h2 className="d4" id="pt-me">You</h2>
          <Dl rows={[['Legal name', r?.legal_name ?? p.user?.full_name ?? ''], ['Email', p.user?.email ?? user.email ?? ''], ['Identity', r ? STATUS[r.identity_status] ?? r.identity_status : 'Checked with your first booking']]} />
          <p className="small muted">Your legal name is locked once you are verified: ask for a change under Your name and password. You change your email under Sign-in below.</p>
        </section>
        <section className="pt-card" aria-labelledby="pt-contact"><h2 className="d4" id="pt-contact">Contact details</h2>
          {r ? <ProfileForm initial={{ mobile: r.mobile ?? p.user?.phone ?? '', address_line1: r.address_line1 ?? '', address_line2: r.address_line2 ?? '', city: r.city ?? '', province: r.province ?? '', postal_code: r.postal_code ?? '', country: r.country ?? 'Canada' }} />
            : <p className="muted">Your contact details are saved with your first booking request.</p>}
        </section>
        {r && <section className="pt-card" aria-labelledby="pt-second" data-testid="profile-secondary-contact"><h2 className="d4" id="pt-second">Secondary contact <span className="small muted">(optional)</span></h2>
          <p className="small muted">Someone we may call if we cannot reach you during a rental.</p>
          <SecondaryContactForm initial={sc ?? null} /></section>}
        {sp && <SelfProfile data={sp} />}
        {si && <SignInSettings state={si} />}
        <AppProfile userId={user.id} deletion />
      </div>
      <aside className="pt-split__aside stack-lg">
        <section className="pt-card" aria-labelledby="pt-card"><h2 className="d4" id="pt-card">Card on File</h2>
          {p.cards.length ? <Dl rows={p.cards.map((c) => [`${c.brand.toUpperCase()} ending ${c.last4}`, `Expires ${String(c.exp_month).padStart(2, '0')}/${c.exp_year}`])} /> : <p className="muted small">Saved when you pay for your first booking.</p>}
        </section>
        <section className="pt-card" aria-labelledby="pt-drv"><h2 className="d4" id="pt-drv">Drivers</h2>
          {p.drivers.length ? <Dl rows={p.drivers.map((d) => [d.full_name, `${d.is_account_holder ? 'You' : 'Additional driver'}, ${STATUS[d.identity_status] ?? d.identity_status}`])} /> : <p className="muted small">None yet. Add a driver from a booking: Manage your trip, Add a driver.</p>}
        </section>
        {nc && <NotifyChannelCard reach={nc} />}
        <PushAlerts userId={user.id} portal="renter" />
        <AppProfile userId={user.id} lock />
      </aside>
    </div>
  );
}
