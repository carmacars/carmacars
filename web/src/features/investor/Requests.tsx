'use client';
import { useState, useTransition } from 'react';
import { investorRequest } from '@/server/actions/investor';

// The two notices an investor may send from the area (07-investor.md section 2): a change of election, a
// change of bank account (we call to take the details; none are typed here) and a transfer request.
export function Requests({ investments, effective }: { investments: Array<{ id: string; label: string }>; effective: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [mode, setMode] = useState('pay');
  const [to, setTo] = useState(''); const [inv, setInv] = useState(investments[0]?.id ?? ''); const [note, setNote] = useState('');
  const send = (a: Parameters<typeof investorRequest>[0], p: Record<string, unknown>) => start(async () => {
    const r = await investorRequest(a, p);
    setMsg(r.ok ? { ok: true, text: 'Received. CarmaCars will confirm in writing.' } : { ok: false, text: r.message });
  });
  return (
    <div className="stack">
      <section className="pt-card" aria-labelledby="el-t"><h2 className="d4" id="el-t">How returns are handled</h2>
        <p className="small">A change applies from the first Return Month that starts at least 10 days after CarmaCars receives it: sent today, from {effective}.</p>
        <fieldset className="stack"><legend className="vh">Election</legend>
          <label className="check"><input type="radio" name="mode" checked={mode === 'pay'} onChange={() => setMode('pay')} /> <span>Paid monthly</span></label>
          <label className="check"><input type="radio" name="mode" checked={mode === 'reinvest'} onChange={() => setMode('reinvest')} /> <span>Reinvested</span></label></fieldset>
        <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => send('election_change', { mode })} data-testid="election-send">Send the notice</button>
      </section>
      <section className="pt-card" aria-labelledby="bk-t"><h2 className="d4" id="bk-t">Bank account</h2>
        <p className="small">We call you at the number on file to take the new details. A change applies 10 days after notice.</p>
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => send('bank_change', {})}>Ask to change the bank account</button>
      </section>
      {investments.length > 0 && <section className="pt-card" aria-labelledby="tr-t"><h2 className="d4" id="tr-t">Transfer request</h2>
        <p className="small">A transfer needs CarmaCars&apos; written consent.</p>
        <div className="field"><label className="label" htmlFor="tr-i">Investment</label><select className="select" id="tr-i" value={inv} onChange={(e) => setInv(e.target.value)}>{investments.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor="tr-to">To (full name)</label><input className="input" id="tr-to" value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="tr-n">Note</label><textarea className="input" id="tr-n" value={note} onChange={(e) => setNote(e.target.value)} /></div>
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !to.trim()} onClick={() => send('transfer_request', { investment: inv, to_name: to, note })}>Send the request</button>
      </section>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
