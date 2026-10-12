import Link from 'next/link';
import { AuthShell, AuthTabs } from '@/features/forms/AuthShell';
import { SignUpForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export async function generateMetadata() {
  const t = await getTokens();
  return pageMeta({ title: fill('Create an account | {{brand}}', t), path: '/create-account', noindex: true, description: fill('Create a {{brand}} account to follow your requests, sign agreements and see statements.', t) });
}
export default async function CreateAccount() {
  const t = await getTokens();
  return (
    <div className="p-auth">
      <AuthShell side="One sign-in for renters, owners and staff." sideText="Renters see bookings, agreements and statements. Owners see their cars, calendar and payouts.">
        <h1 className="d2">Create an account</h1>
        <AuthTabs current="new" />
        <SignUpForm minAge={t.minAge!} />
        <p className="small muted">You do not need an account to <Link className="link" href="/cars">request a car</Link>.</p>
      </AuthShell>
    </div>
  );
}
