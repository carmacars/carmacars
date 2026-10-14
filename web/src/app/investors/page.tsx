import { Suspense } from 'react';
import { AuthShell } from '@/features/forms/AuthShell';
import { SignInForm } from '@/features/forms/AuthForms';
import { seoMeta } from '@/features/seo/meta';
import { fill, getFacts, getTokens } from '@/lib/site';

// Investor sign in only: nothing about investing is published (migration 0025, section 13).
export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Investor sign in | {{brand}}', t), path: '/investors', noindex: true, description: fill('Sign in for existing {{brand}} investors. Investor information is available to signed-in investors only.', t) });
}
export default async function Investors() {
  const [t, f] = await Promise.all([getTokens(), getFacts()]);
  return (
    <div className="p-auth">
      <AuthShell side="Investor sign in" sideText={`For people who already invest with ${t.brand}.`}>
        <h1 className="d2">Sign in to the investor portal</h1>
        <p>Investor information is available to signed-in investors only. Nothing about investing with {t.brand} is published on this site.</p>
        <Suspense fallback={null}><SignInForm idPrefix="iv" next="/investor" /></Suspense>
        {f.email_aliases.investors && <p className="small muted">Existing investors with a question can email <a className="link" href={`mailto:${f.email_aliases.investors}`}>{f.email_aliases.investors}</a>.</p>}
      </AuthShell>
    </div>
  );
}
