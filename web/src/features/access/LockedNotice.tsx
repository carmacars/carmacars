'use client';
import { useSearchParams } from 'next/navigation';

// 1060: a staff account locked after days without a sign-in is told so on the sign-in page (the page itself stays static).
export function LockedNotice() {
  const sp = useSearchParams();
  if (sp.get('locked') !== 'inactivity') return null;
  return (
    <p className="alert alert--warn" role="alert" data-testid="signin-locked">
      <span className="alert__title">Account locked</span>
      <span>Your staff account is locked: it was not used for a while, or two weekly townhalls were missed in a row. Ask an Admin to restore it, then sign in again.</span>
    </p>
  );
}
