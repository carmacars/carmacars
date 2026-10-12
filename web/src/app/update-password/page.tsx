import { Suspense } from 'react';
import { AuthShell } from '@/features/forms/AuthShell';
import { NewPasswordForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Choose a new password', path: '/update-password', noindex: true, description: 'Choose a new password for your account.' });
export default function UpdatePassword() {
  return (
    <div className="p-auth">
      <AuthShell side="Almost done." sideText="Choose a new password. You stay signed in on this device.">
        <h1 className="d2">Choose a new password</h1>
        <Suspense fallback={null}><NewPasswordForm /></Suspense>
      </AuthShell>
    </div>
  );
}
