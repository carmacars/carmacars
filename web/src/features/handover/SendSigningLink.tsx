'use client';
import { useState, useTransition } from 'react';
import { opsAct } from '@/server/actions/ops';

// "Text or email the signing link" (migration 0130): the renter signs on their own phone. The email is the "Sign your
// rental agreement" email again; the text goes from the CarmaCars number with the link to the signing page.
export function SendSigningLink({ booking, mobile, email }: { booking: string; mobile: string | null; email: string | null }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const send = (channel: 'email' | 'text') => start(async () => {
    const r = await opsAct<{ to?: string; status?: string; sent?: boolean }>('signing_link_send', { booking, channel });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: channel === 'text'
      ? (r.data.status === 'skipped' ? `Not texted: ${r.data.to ?? 'the number'} has opted out of texts.` : `Texted to ${r.data.to ?? 'the renter'}.`)
      : `Emailed to ${r.data.to ?? 'the renter'}.` });
  });
  return (
    <div className="stack" style={{ gap: 'var(--s-2)' }}>
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {/* 2026-11-01: by text first; without a mobile number, by email */}
        <button type="button" className={`btn ${mobile ? 'btn--primary' : 'btn--ghost'} btn--sm`} disabled={pending || !mobile} onClick={() => send('text')} data-testid="sign-link-text">Text the signing link</button>
        <button type="button" className={`btn ${mobile ? 'btn--ghost' : 'btn--primary'} btn--sm`} disabled={pending || !email} onClick={() => send('email')} data-testid="sign-link-email">Email the signing link</button>
        {!mobile && <span className="small muted" data-testid="sign-link-no-mobile">No mobile number on file: email the link.</span>}
      </div>
      {msg && <p className={`small ${msg.ok ? '' : 'error'}`} role="status" data-testid="sign-link-result">{msg.text}</p>}
    </div>
  );
}
