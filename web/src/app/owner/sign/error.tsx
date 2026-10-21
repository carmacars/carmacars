'use client';
import { useEffect } from 'react';
import { SignTrouble } from './SignTrouble';

// The last line of defence for the sign page: a friendly message with Try again, never a crashed page.
export default function SignError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => { console.error('owner sign page', error.digest ?? error.message); }, [error]);
  return <SignTrouble retry={<button type="button" className="btn btn--primary" onClick={() => reset()} data-testid="sign-trouble-retry">Try again</button>} />;
}
