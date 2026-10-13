'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// Turo trips from a CSV export (05-va.md section 2): one row per trip with the columns
// trip_ref, plate, start, end, gross, turo_fees, extras, damage (dollars). Rows that fail are listed.
const COLS = ['trip_ref', 'plate', 'start', 'end', 'gross', 'turo_fees', 'extras', 'damage'];
function parse(text: string): Array<Record<string, string>> {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return [];
  const split = (l: string) => l.split(',').map((x) => x.trim().replace(/^"|"$/g, ''));
  const head = split(lines[0]!).map((h) => h.toLowerCase().replace(/\s+/g, '_'));
  const hasHead = head.includes('trip_ref') || head.includes('plate');
  const names = hasHead ? head : COLS;
  return (hasHead ? lines.slice(1) : lines).map((l) => Object.fromEntries(split(l).map((v, i) => [names[i] ?? `c${i}`, v])));
}
const cents = (v: string | undefined) => Math.round(Number(String(v ?? '0').replace(/[$,\s]/g, '')) * 100);

export function TuroImport() {
  const router = useRouter();
  const [text, setText] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="ad-form" data-testid="turo-import" onSubmit={(e) => { e.preventDefault(); start(async () => {
      const rows = parse(text).map((r) => ({ turo_trip_ref: r.trip_ref, plate: r.plate, starts_at: r.start ? new Date(r.start).toISOString() : null, ends_at: r.end ? new Date(r.end).toISOString() : null,
        gross_cents: cents(r.gross), turo_fees_cents: cents(r.turo_fees), company_extras_cents: cents(r.extras), damage_payment_cents: cents(r.damage) }));
      if (!rows.length) { setMsg({ ok: false, text: 'Paste the CSV first.' }); return; }
      const r = await vaAct<{ saved: number; errors: Array<{ row: number; ref: string | null; message: string }> }>('turo_trip_import', { rows });
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      setMsg({ ok: r.data.errors.length === 0, text: `${r.data.saved} saved.${r.data.errors.length ? ' Not saved: ' + r.data.errors.map((x) => `row ${x.row} (${x.ref ?? 'no reference'}): ${x.message}`).join('; ') : ''}` });
      router.refresh();
    }); }}>
      <div className="field ad-field--wide"><label className="label" htmlFor="turo-csv">CSV rows</label>
        <textarea className="input ad-textarea pt-mono" id="turo-csv" rows={5} value={text} onChange={(e) => setText(e.target.value)} placeholder="trip_ref,plate,start,end,gross,turo_fees,extras,damage" aria-describedby="turo-csv-hint" />
        <p className="hint" id="turo-csv-hint">Columns: trip_ref, plate, start, end, gross, turo_fees, extras, damage. Amounts in dollars; dates as 2026-09-02 14:00.</p></div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>{pending ? 'Importing' : 'Import'}</button>
    </form>
  );
}
