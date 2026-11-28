'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Act } from '@/features/admin/Act';

// R51 (5200, REQ-132): a staff member's own line on Admin > Settings > Staff. The extension (Set extension), then Get a
// number: Twilio's monthly price and the last 4 digits of the number it would sell; nothing is bought until the Admin
// presses Buy with that price. Release gives the number back. Added in Quo records the owner's step in Quo's phone menu.
export interface LineRow { extension: string; status: 'no_number' | 'active' | 'released'; words: string; quo_added: boolean; monthly_cents: number | null; currency: string | null }
type Quote = { ok: true; extension: string; name: string; monthly: string; currency: string; number: string } | { ok: false; message: string };

async function post(body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const r = await fetch('/api/staff/phone', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(60_000) });
  return ((await r.json().catch(() => null)) as Record<string, unknown> | null) ?? { ok: false, message: `The server answered ${r.status}` };
}

export function StaffLine({ user, name, line, testId }: { user: string; name: string; line: LineRow | null; testId: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [msg, setMsg] = useState('');
  const run = async (body: Record<string, unknown>, after?: (j: Record<string, unknown>) => void) => {
    setBusy(true); setMsg('');
    const j = await post({ ...body, user_id: user }).catch(() => ({ ok: false, message: 'The server did not answer.' }) as Record<string, unknown>);
    setBusy(false);
    if (after) after(j);
    else if (j.ok) { setQuote(null); setMsg(String(j.line ?? 'Done.')); router.refresh(); }
    else setMsg(String(j.message ?? j.error ?? 'Not done.'));
  };
  return (
    <span className="stack" data-testid={testId}>
      <span className="small">{line ? line.words : 'No extension yet'}{line?.status === 'active' && line.monthly_cents !== null ? ` (${line.currency} ${(line.monthly_cents / 100).toFixed(2)} a month)` : ''}
        {line?.status === 'active' && !line.quo_added ? <span className="ad-flag ad-flag--red"> Add it in Quo</span> : null}</span>
      <span className="ad-actions">
        <Act action="staff_line_set" payload={{ user_id: user }} label={line ? 'Change extension' : 'Set extension'} title={`${name}'s extension`} submitLabel="Save" testId={`${testId}-ext`}
          refresh={['/admin/settings/staff']} done="Saved."
          fields={[{ name: 'extension', label: 'Extension (empty: the next free from 1; a Quo menu takes one digit)', type: 'text', value: line?.extension ?? '', placeholder: '1' }]} />
        {line && line.status !== 'active' && !quote && <button type="button" className="btn btn--sm btn--ghost" disabled={busy} aria-busy={busy} data-testid={`${testId}-quote`}
          onClick={() => void run({ action: 'line_quote' }, (j) => (j.ok ? setQuote(j as Quote) : setMsg(String(j.message ?? j.error ?? 'No price.'))))}>{busy ? 'Asking Twilio' : 'Get a number'}</button>}
        {line?.status === 'active' && <button type="button" className="btn btn--sm btn--quiet" disabled={busy} data-testid={`${testId}-release`}
          onClick={() => { if (window.confirm(`Release ${name}'s number? Calls to extension ${line.extension} stop ringing them, and the monthly charge stops.`)) void run({ action: 'line_release' }); }}>Release</button>}
        {line?.status === 'active' && !line.quo_added && <Act action="staff_line_quo_done" payload={{ user_id: user, done: true }} label="Added in Quo" testId={`${testId}-quo`} refresh={['/admin/settings/staff']} done="Recorded." />}
      </span>
      {quote?.ok && (
        <span className="alert alert--warn stack" role="status" data-testid={`${testId}-confirm`}>
          <span className="alert__title">Buy a line for {quote.name}, extension {quote.extension}?</span>
          <span>A Canadian local number ({quote.number}) costs {quote.currency} {quote.monthly} a month at Twilio, billed to the Twilio account until it is released. Calls to it ring only {quote.name}&apos;s portal and app.</span>
          <span className="ad-actions">
            <button type="button" className="btn btn--sm btn--primary" disabled={busy} aria-busy={busy} data-testid={`${testId}-buy`}
              onClick={() => void run({ action: 'line_buy', confirm: quote.monthly })}>{busy ? 'Buying' : `Buy for ${quote.currency} ${quote.monthly} a month`}</button>
            <button type="button" className="btn btn--sm btn--quiet" onClick={() => setQuote(null)}>Cancel</button>
          </span>
        </span>)}
      {msg && <span className="small" role="status">{msg}</span>}
    </span>
  );
}
