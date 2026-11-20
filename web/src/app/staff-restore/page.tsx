import { AuthShell } from '@/features/forms/AuthShell';
import { seoMeta } from '@/features/seo/meta';
import { RestoreButton } from './RestoreButton';

// r48 CM (3110): the link of the suspension email. One button asks the Admins for access back; Unlock on Staff approves it.
export const dynamic = 'force-dynamic';
export function generateMetadata() {
  return seoMeta({ title: 'Restore your staff access | CarmaCars', path: '/staff-restore', noindex: true, description: 'Ask for your CarmaCars staff access back.' });
}
export default async function StaffRestore({ searchParams }: { searchParams: Promise<{ t?: string }> }) {
  const { t } = await searchParams;
  return (
    <div className="p-auth">
      <AuthShell side="CarmaCars staff" sideText="Staff access is suspended after 5 days in a row without using the portal.">
        <h1 className="d2">You no longer have access</h1>
        <p>Your staff access is suspended. Ask for it back: an Admin approves it, then you can sign in again.</p>
        <RestoreButton token={typeof t === 'string' ? t.slice(0, 64) : ''} />
      </AuthShell>
    </div>
  );
}
