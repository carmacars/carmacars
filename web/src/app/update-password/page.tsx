import Link from 'next/link';
import { Suspense } from 'react';
import { AuthShell } from '@/features/forms/AuthShell';
import { NewPasswordForm, ResetForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';
import { auth } from '@/lib/auth';
import { env } from '@/lib/env';
import { lastEmail } from '@/server/auth-links';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Choose a password', path: '/update-password', noindex: true, description: 'Choose a password for your account.' });

// Reached from the password and invitation emails (through /auth/callback, which signs the person in for this step).
// Without that session (the link expired, or the page was opened directly) it offers a new link instead.
export default async function UpdatePassword({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token } = await searchParams;
  const user = await (await auth()).currentUser();
  const ready = !!user || (env().DATA_BACKEND === 'local' && !!token);
  return (
    <div className="p-auth">
      <AuthShell side="Almost done." sideText="Choose a password. You stay signed in on this device, and we take you to your portal.">
        {ready ? (<>
          <h1 className="d2">Choose a password</h1>
          {user?.email && <p className="muted">For <b data-testid="password-for">{user.email}</b></p>}
          <Suspense fallback={null}><NewPasswordForm /></Suspense>
        </>) : (<>
          <h1 className="d2">This link has expired</h1>
          <p className="muted" data-testid="link-expired">The link to choose a password has expired or was already used. Send a new one, then open it within one hour.</p>
          <ResetForm email={(await lastEmail()) ?? undefined} label="Send me a new link" idPrefix="up" />
          <p className="small"><Link className="link" href="/sign-in">Back to sign in</Link></p>
        </>)}
      </AuthShell>
    </div>
  );
}
