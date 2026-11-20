'use client';
import { useState } from 'react';
import { requestStaffRestore } from '@/server/actions/staff-restore';

export function RestoreButton({ token }: { token: string }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; message: string } | null>(null);
  if (msg?.ok) return <p className="alert alert--ok" role="status" data-testid="restore-sent">{msg.message}</p>;
  return (
    <>
      {msg && <p className="alert alert--error" role="alert">{msg.message}</p>}
      <button type="button" className="btn btn--primary" disabled={busy || !token} data-testid="restore-request"
        onClick={async () => { setBusy(true); setMsg(await requestStaffRestore(token)); setBusy(false); }}>{busy ? 'Sending…' : 'Restore my access'}</button>
    </>
  );
}
