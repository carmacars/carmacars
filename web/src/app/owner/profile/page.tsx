import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { Dl } from '@/features/portal/Blocks';
import { OwnerProfileForm } from '@/features/owner/OwnerForms';
import { requireOwner } from '@/server/owner/data';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/owner/profile', noindex: true, description: 'Your owner details.' });

export default async function OwnerProfilePage() {
  const { home, user } = await requireOwner('/owner/profile');
  const [si, nc] = await Promise.all([signInState(user.id), notifyReach(user.id)]);
  const o = home.owner;
  return (
    <>
      <PageHeader title="Profile" purpose="Your contact details and the details your agreements and registry forms use." />
      <div className="pt-split">
        <section className="pt-card" aria-labelledby="ow-contact"><h2 className="d4" id="ow-contact">Contact details</h2>
          <OwnerProfileForm initial={{ email: o.email ?? '', phone: o.phone ?? '', address_line1: o.address_line1 ?? '', address_line2: o.address_line2 ?? '', city: o.city ?? '', province: o.province ?? 'ON', postal_code: o.postal_code ?? '', hst_number: o.hst_number ?? '' }} />
        </section>
        <aside className="pt-split__aside stack-lg">
          {si && <SignInSettings state={si} />}
          {nc && <NotifyChannelCard reach={nc} />}
          <section className="pt-card" aria-labelledby="ow-legal"><h2 className="d4" id="ow-legal">On your agreements</h2>
            <Dl rows={[['Legal name', o.legal_name], ['Enrolled as', o.owner_type === 'corporation' ? 'A corporation' : 'An individual'], ['Corporation', o.corporation_name ? `${o.corporation_name}${o.corporation_number ? `, no. ${o.corporation_number}` : ''}` : ''], ['Signing officer', o.signing_officer_name ? `${o.signing_officer_name}, ${o.signing_officer_title ?? ''}` : '']]} />
            <p className="small muted">A change of legal name or corporation changes your agreements: call or message us and we prepare them again.</p>
            {o.missing.length > 0 && <p className="pt-note">Still needed for your agreements and registry forms: {o.missing.join(', ')}.</p>}
          </section>
        </aside>
      </div>
    </>
  );
}
