import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { auth } from '@/lib/auth';
import { TwoStepSetup } from '@/features/forms/TwoStep';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Set up two-step sign-in', path: '/two-step/setup', noindex: true, description: 'Add an authenticator app.' });
const safe = (n?: string) => (n && /^\/(?!\/)[\w\-/?=&.]*$/.test(n) ? n : null);

// Enrolment (Supabase Auth TOTP factor). Staff must do this before the staff two-step switch is turned on;
// with the switch on, a staff member without it is sent here after the password.
export default async function Setup({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  const a = await auth();
  if (!(await a.currentUser())) redirect(`/sign-in?next=${encodeURIComponent(`/two-step/setup${next ? `?next=${next}` : ''}`)}`);
  const has = (await a.mfaFactors()).some((f) => f.verified);
  return (
    <div className="container" style={{ maxWidth: '28rem', paddingBlock: 'var(--s-7)' }}>
      <h1 className="d2">Set up two-step sign-in</h1>
      <p className="muted">{has ? 'Two-step sign-in is on for this account. Setting it up again replaces nothing until the new code is checked.' : 'After your password you will type a code from an authenticator app on your phone.'}</p>
      <TwoStepSetup next={safe(next)} />
    </div>
  );
}
