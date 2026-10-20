'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminSaveRow } from '@/server/actions/admin-portal';

// Settings > Discount games (migration 0069): the prize table and the games' weights in plain fields (the database
// checks them again). Saved as a new dated Program settings row, like every program setting.
export interface Prize { key: string; percent_bps?: number; amount_cents?: number; min_days?: number; weight: number }
type Row = { kind: 'percent' | 'amount'; value: string; min_days: string; weight: string };
const GAMES: Array<[string, string]> = [['wheel', 'Spin the wheel'], ['scratch', 'Scratch to reveal'], ['blackjack', 'Quick blackjack'], ['cups', 'Cup shuffle'], ['plinko', 'Plinko']];
const num = (v: string) => /^\d+(\.\d+)?$/.test(v.trim());

export function GameSettings({ prizes, weights }: { prizes: Prize[]; weights: Record<string, number> }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [rows, setRows] = useState<Row[]>(() => prizes.map((p) => ({ kind: p.percent_bps ? 'percent' : 'amount', value: String(p.percent_bps ? p.percent_bps / 100 : (p.amount_cents ?? 0) / 100),
    min_days: p.min_days ? String(p.min_days) : '', weight: String(p.weight) })));
  const [w, setW] = useState<Record<string, string>>(() => Object.fromEntries(GAMES.map(([k]) => [k, String(weights[k] ?? 0)])));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const total = rows.reduce((s, r) => s + (num(r.weight) ? Number(r.weight) : 0), 0);
  const set = (i: number, k: keyof Row, v: string) => setRows((x) => x.map((r, j) => (j === i ? { ...r, [k]: v } : r)));

  function save(e: React.FormEvent) {
    e.preventDefault();
    if (!rows.length) { setMsg({ ok: false, text: 'Keep at least one prize.' }); return; }
    for (const [i, r] of rows.entries()) {
      if (!num(r.value) || Number(r.value) <= 0) { setMsg({ ok: false, text: `Prize ${i + 1}: enter the ${r.kind === 'percent' ? 'percentage' : 'amount'}.` }); return; }
      if (r.kind === 'percent' && Number(r.value) > 50) { setMsg({ ok: false, text: `Prize ${i + 1}: at most 50% off.` }); return; }
      if (!num(r.weight) || Number(r.weight) <= 0) { setMsg({ ok: false, text: `Prize ${i + 1}: the chance must be above 0.` }); return; }
      if (r.min_days && (!/^\d+$/.test(r.min_days) || Number(r.min_days) < 1 || Number(r.min_days) > 30)) { setMsg({ ok: false, text: `Prize ${i + 1}: minimum days from 1 to 30, or empty.` }); return; }
    }
    if (!Object.values(w).some((v) => num(v) && Number(v) > 0)) { setMsg({ ok: false, text: 'Keep at least one game on.' }); return; }
    const game_prizes = rows.map((r, i) => {
      const v = Number(r.value);
      const key = r.kind === 'percent' ? `pct${String(v).replace('.', '_')}` : `amt${String(v).replace('.', '_')}`;
      return { key: rows.findIndex((x, j) => j < i && x.kind === r.kind && Number(x.value) === v) >= 0 ? `${key}_${i}` : key,
        ...(r.kind === 'percent' ? { percent_bps: Math.round(v * 100) } : { amount_cents: Math.round(v * 100) }), ...(r.min_days ? { min_days: Number(r.min_days) } : {}), weight: Number(r.weight) };
    });
    const game_weights = Object.fromEntries(GAMES.map(([k]) => [k, num(w[k] ?? '') ? Number(w[k]) : 0]));
    start(async () => {
      const r = await adminSaveRow('program_settings', { game_prizes, game_weights }, 'current');
      setMsg(r.ok ? { ok: true, text: 'Saved. New games use these prizes; codes already sent keep theirs.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
  }
  return (
    <form onSubmit={save} className="stack" data-testid="game-settings">
      <fieldset className="stack-sm"><legend className="d4">Prizes</legend>
        <p className="small muted">Every play wins one prize. The chance is a weight: with 70, 25, 4 and 1 the first prize comes up 70 times in 100. The game&apos;s short terms list the prizes and say the chances differ.</p>
        <div className="ad-scroll"><table className="data"><thead><tr><th scope="col">Prize</th><th scope="col">Off</th><th scope="col">Minimum days</th><th scope="col">Chance</th><th scope="col"><span className="vh">Remove</span></th></tr></thead>
          <tbody>{rows.map((r, i) => (<tr key={i}>
            <td><label className="vh" htmlFor={`${idp}-k${i}`}>Prize {i + 1} kind</label><select className="select" id={`${idp}-k${i}`} value={r.kind} onChange={(e) => set(i, 'kind', e.target.value)}><option value="percent">Percent off</option><option value="amount">Dollars off</option></select></td>
            <td><label className="vh" htmlFor={`${idp}-v${i}`}>Prize {i + 1} value</label><input className="input" id={`${idp}-v${i}`} inputMode="decimal" value={r.value} onChange={(e) => set(i, 'value', e.target.value)} /></td>
            <td><label className="vh" htmlFor={`${idp}-m${i}`}>Prize {i + 1} minimum rental days</label><input className="input" id={`${idp}-m${i}`} inputMode="numeric" value={r.min_days} placeholder="any" onChange={(e) => set(i, 'min_days', e.target.value)} /></td>
            <td><label className="vh" htmlFor={`${idp}-w${i}`}>Prize {i + 1} chance</label><input className="input" id={`${idp}-w${i}`} inputMode="decimal" value={r.weight} onChange={(e) => set(i, 'weight', e.target.value)} />
              <span className="small muted">{total > 0 && num(r.weight) ? `${Math.round((Number(r.weight) / total) * 1000) / 10}%` : ''}</span></td>
            <td><button type="button" className="btn btn--quiet btn--sm" onClick={() => setRows((x) => x.filter((_, j) => j !== i))}>Remove</button></td>
          </tr>))}</tbody></table></div>
        {rows.length < 8 && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setRows((x) => [...x, { kind: 'percent', value: '5', min_days: '', weight: '1' }])}>Add a prize</button>}
      </fieldset>
      <fieldset className="stack-sm"><legend className="d4">Games</legend>
        <p className="small muted">Each visitor gets one game at random. Equal numbers give equal chances; 0 turns a game off.</p>
        <div className="ad-cols ad-cols--3">{GAMES.map(([k, l]) => <label key={k} className="field" htmlFor={`${idp}-g${k}`}><span className="label">{l}</span>
          <input className="input" id={`${idp}-g${k}`} inputMode="decimal" value={w[k]} onChange={(e) => setW((x) => ({ ...x, [k]: e.target.value }))} /></label>)}</div>
      </fieldset>
      <div><button type="submit" className="btn btn--primary" disabled={pending}>{pending ? 'Saving' : 'Save prizes and games'}</button></div>
      {msg && <p className={msg.ok ? 'small' : 'small ad-err'} role="status">{msg.text}</p>}
    </form>
  );
}
