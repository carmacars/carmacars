'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { resendDriverLink } from '@/server/actions/portal';
import { CopyLink } from './CopyLink';
import { useAct } from './useAct';

// An additional driver's signing link on the renter's booking: copy it while it is valid, or send a new one (every
// earlier link stops working, and the driver is emailed when we have their address).
export function DriverLink({ number, signerId, name, url, expiresText, expired, sentText }: {
  number: string; signerId: string; name: string; url: string | null; expiresText: string; expired: boolean; sentText: string | null;
}) {
  const router = useRouter();
  const [fresh, setFresh] = useState<{ url: string; emailed: string | null } | null>(null);
  const a = useAct<{ url: string; emailed: string | null; expiresAt: string }>();
  const link = fresh?.url ?? (expired ? null : url);
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }} data-testid={`driver-link-${signerId}`}>
      <p className="small">{fresh ? (fresh.emailed ? `New link emailed to ${fresh.emailed}.` : 'New link made. Copy it and send it to them.') : expired ? `The link for ${name} has expired.` : `Link valid until ${expiresText}.`}{!fresh && sentText ? ` ${sentText}` : ''}</p>
      <div className="row">
        {link && <CopyLink url={link} label="Copy their signing link" />}
        <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="driver-link-resend"
          onClick={() => a.run(() => resendDriverLink(number, signerId), (r) => { if (r.ok) { setFresh({ url: r.data.url, emailed: r.data.emailed }); router.refresh(); } })}>
          {a.pending ? 'Sending' : 'Send a new link'}
        </button>
      </div>
      {a.res && !a.res.ok && <p className="error" role="alert">{a.res.message}</p>}
    </div>
  );
}
