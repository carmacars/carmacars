'use client';
import { PortalError } from '@/components/ui/PortalError';

// r49: a crash on a page of this portal shows inside the portal (components/ui/PortalError.tsx).
export default function PortalPageError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <PortalError error={error} reset={reset} />;
}
