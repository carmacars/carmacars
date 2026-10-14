import { Suspense } from 'react';
import { AuthShell } from '@/features/forms/AuthShell';
import { NewPasswordForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Choose a password', path: '/update-password', noindex: true, description: 'Choose a password for your account.' });

// Reached from the password and invitation emails (through /auth/callback, which signs the person in for this step).
// The page itself is static (served from the cache, so it never meets the Worker's CPU limit when someone opens their
// link); saving checks the link's session, and without one the form offers a new link in one step.
export default function UpdatePassword() {
  return (
    <div className="p-auth">
      <AuthShell side="Almost done." sideText="Choose a password. You stay signed in on this device, and we take you to your portal.">
        <h1 className="d2">Choose a password</h1>
        <Suspense fallback={null}><NewPasswordForm /></Suspense>
      </AuthShell>
    </div>
  );
}
