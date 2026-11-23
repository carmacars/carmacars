'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { useDoor } from '@/features/admin/door';
import { adminToast } from '@/features/admin/shell/toast';
import { importPayload, readBankFile, totals, type BankFile } from './bank-file';

type Result = { repeat?: boolean; account: string; lines_in: number; lines_new: number; lines_duplicate: number; lines_matched: number; lines_unmatched: number };
type Account = { id: string; nickname: string; last4: string; currency: string };

// Release 49 (3480): drop the CSV or OFX download from RBC online banking. The browser reads it; only its lines go to the
// database (the last four digits of the account and a hash of its number, never the full number), which keeps each line
// once and matches it to its payout, payment or expense. The same file twice adds nothing.
export function BankImport({ accounts, refresh }: { accounts: Account[]; refresh: string }) {
  const { act } = useDoor();
  const router = useRouter();
  const [file, setFile] = useState<{ name: string; text: string; parsed: BankFile } | null>(null);
  const [which, setWhich] = useState<Record<number, string>>({});
  const [balance, setBalance] = useState('');
  const [balanceOn, setBalanceOn] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<Result[]>([]);
  const [pending, start] = useTransition();

  const load = async (f: File) => {
    setErr(null); setDone([]); setFile(null);
    if (f.size > 5 * 1024 * 1024) { setErr('That file is over 5 MB: download a shorter period.'); return; }
    const text = await f.text();
    try {
      const parsed = readBankFile(text);
      setFile({ name: f.name, text, parsed });
      // an account already known by its last four digits is picked for it
      setWhich(Object.fromEntries(parsed.accounts.map((a, i) => [i, accounts.find((k) => k.last4 === a.last4 && k.currency === a.currency)?.id ?? ''])));
    } catch (e) { setErr(e instanceof Error ? e.message : 'This file could not be read.'); }
  };
  const typed = () => { const n = Number(balance.replace(/[$,\s]/g, '')); return balance.trim() && Number.isFinite(n) ? Math.round(n * 100) : null; };
  const run = () => start(async () => {
    if (!file) return;
    setErr(null);
    const out: Result[] = [];
    const single = file.parsed.accounts.length === 1;
    for (const [i, a] of file.parsed.accounts.entries()) {
      if (!a.lines.length) continue;
      if (!a.last4 && !which[i]) { setErr('The file does not name the account: choose it first.'); return; }
      const p = await importPayload(file.parsed, i, file.text, file.name, { account_id: which[i] || null, ...(single && typed() !== null ? { balance_cents: typed(), balance_on: balanceOn || null } : {}) });
      const r = await act<Result>('bank_import', p, [refresh]);
      if (!r.ok) { setErr(r.message); return; }
      out.push(r.data);
    }
    setDone(out);
    const n = out.reduce((t, r) => t + r.lines_new, 0);
    adminToast(n ? `${n} new line(s) imported.` : 'Nothing new: these lines were already in.');
    router.refresh();
  });

  return (
    <section className="pt-card ad-card ad-form" aria-labelledby="bi-h" data-testid="bank-import">
      <h2 className="d4" id="bi-h">Import from RBC online banking</h2>
      <p className="small muted">RBC online banking, the account, Download transactions: CSV (or OFX, which also has the balance). The file stays on this computer; only its lines are saved. Importing the same days again adds nothing.</p>
      <div className="ad-fields">
        <div className="field ad-field ad-field--wide">
          <label className="label" htmlFor="bi-file">The download (CSV or OFX)</label>
          <input className="input" id="bi-file" type="file" accept=".csv,.ofx,.qfx,text/csv,application/x-ofx" data-testid="bank-import-file"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void load(f); }} />
        </div>
      </div>
      {file ? (
        <div className="stack" data-testid="bank-import-preview">
          {file.parsed.accounts.map((a, i) => {
            const s = totals(a.lines);
            return (
              <div key={i} className="ad-fields">
                <p className="small">
                  <b>{a.last4 ? `Account ending ${a.last4}` : 'Account'} ({a.currency})</b>: {s.count} line(s), {s.from ?? ''} to {s.to ?? ''}, in {money(s.in_cents, { cents: true })}, out {money(s.out_cents, { cents: true })}
                  {a.balance_cents !== null ? <>, balance {money(a.balance_cents, { cents: true })} on {a.balance_on}</> : null}
                </p>
                <div className="field ad-field">
                  <label className="label" htmlFor={`bi-acct-${i}`}>Account</label>
                  <select className="select" id={`bi-acct-${i}`} value={which[i] ?? ''} onChange={(e) => setWhich({ ...which, [i]: e.target.value })}>
                    <option value="">{a.last4 ? `New: RBC ${a.currency} ending ${a.last4}` : 'Choose the account'}</option>
                    {accounts.filter((k) => k.currency === a.currency).map((k) => <option key={k.id} value={k.id}>{k.nickname} · {k.last4}</option>)}
                  </select>
                </div>
              </div>
            );
          })}
          {file.parsed.accounts.length === 1 && file.parsed.accounts[0]!.balance_cents === null ? (
            <div className="ad-fields">
              <div className="field ad-field"><label className="label" htmlFor="bi-bal">Balance shown in online banking ($)</label>
                <input className="input" id="bi-bal" inputMode="decimal" value={balance} onChange={(e) => setBalance(e.target.value)} placeholder="Optional" /></div>
              <div className="field ad-field"><label className="label" htmlFor="bi-bal-on">Balance as at</label>
                <input className="input" id="bi-bal-on" type="date" value={balanceOn} onChange={(e) => setBalanceOn(e.target.value)} /></div>
            </div>
          ) : null}
          {file.parsed.warnings.map((w) => <p key={w} className="small muted">{w}</p>)}
          <div className="ad-actions">
            <button type="button" className="btn btn--primary" onClick={run} disabled={pending} aria-busy={pending} data-testid="bank-import-run">
              {pending ? 'Importing...' : 'Import the lines'}
            </button>
          </div>
        </div>
      ) : null}
      {err ? <p className="small ad-late" role="alert" data-testid="bank-import-error">{err}</p> : null}
      {done.length ? (
        <ul className="small" data-testid="bank-import-done" aria-live="polite">
          {done.map((r) => <li key={r.account}>{r.account}: {r.repeat ? 'this file was already imported' : `${r.lines_new} new, ${r.lines_duplicate} already in, ${r.lines_matched} matched by themselves, ${r.lines_unmatched} to match`}</li>)}
        </ul>
      ) : null}
    </section>
  );
}
