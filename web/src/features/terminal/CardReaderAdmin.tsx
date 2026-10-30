'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { pairReader, removeReader } from '@/server/actions/card-tools';
import { Card, Table, t } from '@/features/admin/ui';

// Settings > Card reader (0202): the Stripe Terminal S700. Pair reader takes the three-word pairing code the reader shows
// (Settings > Generate pairing code on the S700) and registers it at Stripe, to a Terminal location made from the mailing
// address. Card payments and deposit holds are then started from a booking.
export interface TerminalState { mailing_address: string | null; legal_name: string | null;
  location: { stripe_location_id: string; address: string; created_at: string } | null;
  readers: Array<{ id: string; label: string; device_type: string | null; serial_number: string | null; paired_at: string; paired_by: string | null }> }

export function CardReaderAdmin({ s }: { s: TerminalState }) {
  const router = useRouter();
  const [code, setCode] = useState('');
  const [label, setLabel] = useState('Front desk');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  return (<>
    <Card title="Pair reader" testId="pair-reader">
      <p className="small">On the S700: swipe from the left edge, open Settings, then Generate pairing code. Type the three words it shows here. The reader is registered at Stripe to the location {s.location ? <>made from {s.location.address}</> : <>made from the mailing address in Site settings ({s.mailing_address ?? 'not set yet'})</>}. Card statements read {s.legal_name ?? 'the company name'} (the Stripe account&apos;s statement descriptor).</p>
      <form className="ad-form ad-form--narrow" aria-label="Pair reader" onSubmit={(e) => { e.preventDefault(); run(async () => {
        const r = await pairReader({ code, label });
        setMsg({ ok: r.ok, text: r.ok ? `${r.data.label} is paired. Start a card payment from a booking's Money tab.` : r.message });
        if (r.ok) { setCode(''); router.refresh(); }
      }); }}>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="pr-code">Pairing code</label><input className="input" id="pr-code" value={code} onChange={(e) => setCode(e.target.value)} placeholder="word-word-word" autoComplete="off" data-testid="pr-code" /></div>
          <div className="field ad-field"><label className="label" htmlFor="pr-label">Name</label><input className="input" id="pr-label" value={label} onChange={(e) => setLabel(e.target.value)} maxLength={60} data-testid="pr-label" /></div>
        </div>
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !code.trim()} data-testid="pr-go">{pending ? 'Pairing' : 'Pair reader'}</button>
      </form>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="pr-message"><span>{msg.text}</span></p>}
    </Card>
    <Card title={`Readers (${s.readers.length})`} testId="readers">
      <Table rows={s.readers as unknown as Array<Record<string, unknown>>} empty="No reader paired yet." cols={[
        { key: 'label', label: 'Name' }, { key: 'device_type', label: 'Model', render: (r) => (r.device_type === 'stripe_s700' ? 'Stripe Reader S700' : String(r.device_type ?? '')) },
        { key: 'serial_number', label: 'Serial' }, { key: 'paired_at', label: 'Paired', render: (r) => `${t(r.paired_at)}${r.paired_by ? ` by ${String(r.paired_by)}` : ''}` },
        { key: 'x', label: '', render: (r) => <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(async () => { const x = await removeReader({ id: String(r.id) }); setMsg({ ok: x.ok, text: x.ok ? 'Removed.' : x.message }); router.refresh(); })}>Remove</button> }]} />
    </Card>
  </>);
}
