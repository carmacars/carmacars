import Link from 'next/link';
import { AuthShell } from '@/features/forms/AuthShell';
import { ResetForm } from '@/features/forms/AuthForms';
import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Reset your password', path: '/reset-password', noindex: true, description: 'Get a link by email to choose a new password.' });
export default function Reset() {
  return (
    <div className="p-auth">
      <AuthShell side="Locked out?" sideText="We email you a link to choose a new password. Nothing else changes on your account.">
        <h1 className="d2">Reset your password</h1>
        <ResetForm />
        <p className="small"><Link className="link" href="/sign-in">Back to sign in</Link></p>
      </AuthShell>
    </div>
  );
}
