import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { auth } from '@/lib/auth';
import { TwoStepCode } from '@/features/forms/TwoStep';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Two-step sign-in', path: '/two-step', noindex: true, description: 'The second step of signing in.' });
const safe = (n?: string) => (n && /^\/(?!\/)[\w\-/?=&.]*$/.test(n) ? n : null);

// The second step (Supabase Auth TOTP challenge): the session becomes aal2.
export default async function TwoStep({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  const a = await auth();
  if (!(await a.currentUser())) redirect(`/sign-in?next=${encodeURIComponent(safe(next) ?? '/')}`);
  const verified = (await a.mfaFactors()).filter((f) => f.verified);
  if (!verified.length) redirect(`/two-step/setup?next=${encodeURIComponent(safe(next) ?? '')}`);
  return (
    <div className="container" style={{ maxWidth: '28rem', paddingBlock: 'var(--s-7)' }}>
      <h1 className="d2">Two-step sign-in</h1>
      <p className="muted">Open your authenticator app and type the code it shows for CarmaCars.</p>
      <TwoStepCode next={safe(next)} />
      <p className="small"><Link className="link" href="/two-step/setup">Lost the app? Ask an Admin to reset it.</Link></p>
    </div>
  );
}
