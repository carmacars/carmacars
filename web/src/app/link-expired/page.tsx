import Link from 'next/link';
import { AuthShell } from '@/features/forms/AuthShell';
import { ResendConfirmForm, ResetForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';
import { lastEmail } from '@/server/auth-links';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'This link has expired', path: '/link-expired', noindex: true, description: 'Get a new link by email.' });

// Where an email link that has expired (24 hours) or was already used lands (src/app/auth/callback/route.ts).
// One button sends a new one; the address asked with on this device is filled in.
export default async function LinkExpired({ searchParams }: { searchParams: Promise<{ kind?: string }> }) {
  const { kind } = await searchParams;
  const email = (await lastEmail()) ?? undefined;
  const confirm = kind === 'confirm';
  return (
    <div className="p-auth">
      <AuthShell side="Links work once, for 24 hours." sideText="That keeps your account safe if an old email is opened by someone else. A new link takes a minute.">
        <h1 className="d2">This link has expired</h1>
        <p className="muted" data-testid="link-expired">{confirm
          ? 'The link to confirm your email has expired or was already used. Send a new one, then open it within 24 hours.'
          : kind === 'invite'
            ? 'Your invitation link has expired or was already used. Your account is still there: send yourself a link to choose your password, then open it within 24 hours.'
            : 'The link to choose a password has expired or was already used. Send a new one, then open it within 24 hours.'}</p>
        {confirm ? <ResendConfirmForm email={email} /> : <ResetForm email={email} label="Send me a new link" idPrefix="le" />}
        <p className="small"><Link className="link" href="/sign-in">Back to sign in</Link></p>
      </AuthShell>
    </div>
  );
}
