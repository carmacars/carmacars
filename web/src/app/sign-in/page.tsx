import Link from 'next/link';
import { Suspense } from 'react';
import { AuthShell, AuthTabs } from '@/features/forms/AuthShell';
import { ProviderButtons } from '@/features/forms/ProviderButtons';
import { SignInForm } from '@/features/forms/AuthForms';
import { seoMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Sign in | {{brand}}', t), path: '/sign-in', noindex: true, description: fill('Sign in to {{brand}} to see your bookings, agreements, statements and, for owners, your cars and payouts.', t) });
}
export default function SignIn() {
  return (
    <div className="p-auth">
      <AuthShell side="One sign-in for renters, owners and staff." sideText="Renters see bookings, agreements and statements. Owners see their cars, calendar and payouts.">
        <h1 className="d2">Sign in</h1>
        <AuthTabs current="in" />
        <Suspense fallback={null}><ProviderButtons intent="signin" /></Suspense>
        <Suspense fallback={null}><SignInForm /></Suspense>
        <p className="small muted">You do not need an account to <Link className="link" href="/cars">request a car</Link>.</p>
      </AuthShell>
    </div>
  );
}
