'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { claimGiftCard } from '@/server/actions/gift-cards';

// Add a gift card to the account by its code (the email's link fills it in). The database checks the code, who may add
// it (a gifted rental belongs to the address it was sent to) and limits tries.
export function ClaimGiftCard({ initial }: { initial: string }) {
  const router = useRouter();
  const [code, setCode] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);
  const go = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setMsg(null);
    const r = await claimGiftCard(code);
    setBusy(false);
    if (!r.ok) { setMsg({ kind: 'error', text: r.message }); return; }
    setMsg({ kind: 'ok', text: r.data.already ? 'This gift card is already in your account.' : `Added: ${money(r.data.card.balance_cents, { cents: true })} on the card ending ${r.data.card.code_last4}.` });
    setCode('');
    router.refresh();
  };
  return (
    <form className="gc-claim" onSubmit={go} noValidate aria-label="Add a gift card">
      <div className="field"><label className="label" htmlFor="gc-claim-code">Add a gift card code</label>
        <input className="input gc-code-input" id="gc-claim-code" value={code} onChange={(e) => setCode(e.target.value)} placeholder="CCGC-XXXX-XXXX-XXXX" autoComplete="off" autoCapitalize="characters" spellCheck={false} enterKeyHint="done" data-testid="gift-claim-code" /></div>
      <button className="btn btn--primary" type="submit" disabled={busy || !code.trim()} aria-busy={busy} data-testid="gift-claim">{busy ? 'Adding' : 'Add'}</button>
      {msg && <p className={`alert gc-claim__msg ${msg.kind === 'ok' ? 'alert--ok' : 'alert--error'}`} role={msg.kind === 'ok' ? 'status' : 'alert'} data-testid="gift-claim-message"><span>{msg.text}</span></p>}
    </form>
  );
}
