import { Dl } from '@/features/portal/Blocks';
import { OwnerProfileForm } from '@/features/owner/OwnerForms';
import type { OwnerCtx } from '@/features/owner/ctx';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { selfProfile } from '@/server/self-profile';
import { SelfProfile } from '@/features/portal/SelfProfile';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AppProfile } from '@/features/app-shell/AppProfile';

// Account > Profile: your contact details and the details your agreements and registry forms use.
export async function ProfileTab({ home, user }: OwnerCtx) {
  const [si, nc, sp] = await Promise.all([signInState(user.id), notifyReach(user.id), selfProfile(user.id)]);
  const o = home.owner;
  return (
    <>
      <div className="pt-split">
        <section className="pt-card" aria-labelledby="ow-contact"><h2 className="d4" id="ow-contact">Contact details</h2>
          <OwnerProfileForm initial={{ email: o.email ?? '', phone: o.phone ?? '', address_line1: o.address_line1 ?? '', address_line2: o.address_line2 ?? '', city: o.city ?? '', province: o.province ?? 'ON', postal_code: o.postal_code ?? '', hst_number: o.hst_number ?? '' }} />
        </section>
        <aside className="pt-split__aside stack-lg">
          {sp && <SelfProfile data={sp} />}
          {si && <SignInSettings state={si} />}
          {nc && <NotifyChannelCard reach={nc} />}
          <PushAlerts userId={user.id} portal="owner" />
          <AppProfile userId={user.id} lock />
          <section className="pt-card" aria-labelledby="ow-legal"><h2 className="d4" id="ow-legal">On your agreements</h2>
            <Dl rows={[['Legal name', o.legal_name], ['Enrolled as', o.owner_type === 'corporation' ? 'A corporation' : 'An individual'], ['Corporation', o.corporation_name ? `${o.corporation_name}${o.corporation_number ? `, no. ${o.corporation_number}` : ''}` : ''], ['Signing officer', o.signing_officer_name ? `${o.signing_officer_name}, ${o.signing_officer_title ?? ''}` : '']]} />
            <p className="small muted">A change of corporation changes your agreements: call or message us and we prepare them again. For a change of your own name, use Request a name change above.</p>
            {o.missing.length > 0 && <p className="pt-note">Still needed for your agreements and registry forms: {o.missing.join(', ')}.</p>}
          </section>
          <AppProfile userId={user.id} deletion />
        </aside>
      </div>
    </>
  );
}
