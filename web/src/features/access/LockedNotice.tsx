'use client';
import { useSearchParams } from 'next/navigation';

// 1060: a staff account locked after days without a sign-in is told so on the sign-in page (the page itself stays static).
export function LockedNotice() {
  const sp = useSearchParams();
  if (sp.get('locked') !== 'inactivity') return null;
  return (
    <p className="alert alert--warn" role="alert" data-testid="signin-locked">
      <span className="alert__title">Access suspended</span>
      <span>Your staff access is suspended: the portal was not used for 5 days in a row, or two weekly townhalls were missed in a row. Use the restore link in the email we sent you; an Admin approves it.</span>
    </p>
  );
}
