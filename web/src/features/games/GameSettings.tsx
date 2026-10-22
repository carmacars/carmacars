'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminSaveRow } from '@/server/actions/admin-portal';
import { expectedCost, prizeCost, type PrizeRow } from './rules';

// Settings > Discount games (migrations 0069 and 0081): the prize table and the games' weights in plain fields (the
// database checks them again). A prize is a percentage, dollars or free days, with its own minimum rental length and
// its own cap (a percentage or free days without one takes the games' cap). Below the table: what one claimed code is
// expected to cost on the average booking, worked out live from the table. Saved as a new dated Program settings row.
export type Prize = PrizeRow;
type Kind = 'percent' | 'amount' | 'days';
type Row = { kind: Kind; value: string; min_days: string; cap: string; weight: string };
const GAMES: Array<[string, string]> = [['wheel', 'Spin the wheel'], ['scratch', 'Scratch to reveal'], ['blackjack', 'Quick blackjack'], ['cups', 'Cup shuffle'], ['plinko', 'Plinko'], ['pack', 'Card pack'],
  ['coin', 'Coin flip'], ['dice', 'Dice roll'], ['slots', 'Slot machine'], ['drop', 'Prize drop'], ['mystery', 'Mystery box']];
const num = (v: string) => /^\d+(\.\d+)?$/.test(v.trim());
const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
export interface CostBasis { source: 'bookings' | 'rates'; bookings: number; charge_cents: number; days: number }

const toRow = (p: Prize): Row => ({
  kind: p.percent_bps ? 'percent' : p.free_days ? 'days' : 'amount',
  value: String(p.percent_bps ? p.percent_bps / 100 : p.free_days ? p.free_days : (p.amount_cents ?? 0) / 100),
  min_days: p.min_days ? String(p.min_days) : '', cap: p.max_cents ? String(p.max_cents / 100) : '', weight: String(p.weight)
});
function toPrize(r: Row, i: number, rows: Row[]): Prize | null {
  if (!num(r.value) || !num(r.weight)) return null;
  const v = Number(r.value);
  const base = r.kind === 'percent' ? `pct${String(v).replace('.', '_')}` : r.kind === 'days' ? `day${v}` : `amt${String(v).replace('.', '_')}`;
  const dup = rows.findIndex((x, j) => j < i && x.kind === r.kind && Number(x.value) === v) >= 0;
  return { key: dup ? `${base}_${i}` : base,
    ...(r.kind === 'percent' ? { percent_bps: Math.round(v * 100) } : r.kind === 'days' ? { free_days: Math.round(v) } : { amount_cents: Math.round(v * 100) }),
    ...(r.min_days ? { min_days: Number(r.min_days) } : {}), ...(r.cap && r.kind !== 'amount' && num(r.cap) ? { max_cents: Math.round(Number(r.cap) * 100) } : {}),
    weight: Number(r.weight) };
}

export function GameSettings({ prizes, weights, cap, basis }: { prizes: Prize[]; weights: Record<string, number>; cap: number | null; basis: CostBasis | null }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [rows, setRows] = useState<Row[]>(() => prizes.map(toRow));
  const [w, setW] = useState<Record<string, string>>(() => Object.fromEntries(GAMES.map(([k]) => [k, String(weights[k] ?? 0)])));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const total = rows.reduce((s, r) => s + (num(r.weight) ? Number(r.weight) : 0), 0);
  const set = (i: number, k: keyof Row, v: string) => setRows((x) => x.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  const live = rows.map((r, i) => toPrize(r, i, rows)).filter((p): p is Prize => p !== null);
  const cost = basis ? expectedCost(live, basis, cap) : null;

  function save(e: React.FormEvent) {
    e.preventDefault();
    if (!rows.length) { setMsg({ ok: false, text: 'Keep at least one prize.' }); return; }
    for (const [i, r] of rows.entries()) {
      const what = r.kind === 'percent' ? 'percentage' : r.kind === 'days' ? 'number of free days' : 'amount';
      if (!num(r.value) || Number(r.value) <= 0) { setMsg({ ok: false, text: `Prize ${i + 1}: enter the ${what}.` }); return; }
      if (r.kind === 'percent' && Number(r.value) > 50) { setMsg({ ok: false, text: `Prize ${i + 1}: at most 50% off.` }); return; }
      if (r.kind === 'days' && (!/^\d+$/.test(r.value.trim()) || Number(r.value) > 7)) { setMsg({ ok: false, text: `Prize ${i + 1}: free days from 1 to 7.` }); return; }
      if (r.kind === 'days' && !(Number(r.min_days) > Number(r.value))) { setMsg({ ok: false, text: `Prize ${i + 1}: free days need a minimum rental longer than the free days.` }); return; }
      if (!num(r.weight) || Number(r.weight) <= 0) { setMsg({ ok: false, text: `Prize ${i + 1}: the chance must be above 0.` }); return; }
      if (r.min_days && (!/^\d+$/.test(r.min_days) || Number(r.min_days) < 1 || Number(r.min_days) > 30)) { setMsg({ ok: false, text: `Prize ${i + 1}: minimum days from 1 to 30, or empty.` }); return; }
      if (r.cap && r.kind !== 'amount' && (!num(r.cap) || Number(r.cap) < 1 || Number(r.cap) > 1000)) { setMsg({ ok: false, text: `Prize ${i + 1}: a cap from $1 to $1,000, or empty.` }); return; }
    }
    if (!Object.values(w).some((v) => num(v) && Number(v) > 0)) { setMsg({ ok: false, text: 'Keep at least one game on.' }); return; }
    const game_prizes = rows.map((r, i) => toPrize(r, i, rows)!);
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
        <p className="small muted">Every play wins one prize. The chance is a weight: with 69, 25, 4, 1, 0.6, 0.3 and 0.1 the first prize comes up 69 times in 100. A prize with a minimum length applies only to rentals that long; a cap is the most it takes off one booking (empty: the games&apos; cap{cap ? ` of ${dollars(cap)}` : ''} for a percentage or free days). A free day is the booking&apos;s average day of the rental charge. Prizes with a chance of 1 in 100 or less get a bigger celebration. The game&apos;s short terms list the prizes and say the chances differ.</p>
        <div className="ad-scroll"><table className="data"><thead><tr><th scope="col">Prize</th><th scope="col">Off</th><th scope="col">Minimum days</th><th scope="col">Cap ($)</th><th scope="col">Chance</th><th scope="col">On the average booking</th><th scope="col"><span className="vh">Remove</span></th></tr></thead>
          <tbody>{rows.map((r, i) => {
            const p = toPrize(r, i, rows);
            return (<tr key={i}>
              <td><label className="vh" htmlFor={`${idp}-k${i}`}>Prize {i + 1} kind</label><select className="select" id={`${idp}-k${i}`} value={r.kind} onChange={(e) => set(i, 'kind', e.target.value)}><option value="percent">Percent off</option><option value="amount">Dollars off</option><option value="days">Free days</option></select></td>
              <td><label className="vh" htmlFor={`${idp}-v${i}`}>Prize {i + 1} value</label><input className="input" id={`${idp}-v${i}`} inputMode="decimal" value={r.value} onChange={(e) => set(i, 'value', e.target.value)} /></td>
              <td><label className="vh" htmlFor={`${idp}-m${i}`}>Prize {i + 1} minimum rental days</label><input className="input" id={`${idp}-m${i}`} inputMode="numeric" value={r.min_days} placeholder="any" onChange={(e) => set(i, 'min_days', e.target.value)} /></td>
              <td><label className="vh" htmlFor={`${idp}-c${i}`}>Prize {i + 1} cap in dollars</label><input className="input" id={`${idp}-c${i}`} inputMode="decimal" value={r.kind === 'amount' ? '' : r.cap} disabled={r.kind === 'amount'}
                placeholder={r.kind === 'amount' ? 'its amount' : cap ? String(cap / 100) : 'none'} onChange={(e) => set(i, 'cap', e.target.value)} /></td>
              <td><label className="vh" htmlFor={`${idp}-w${i}`}>Prize {i + 1} chance</label><input className="input" id={`${idp}-w${i}`} inputMode="decimal" value={r.weight} onChange={(e) => set(i, 'weight', e.target.value)} />
                <span className="small muted">{total > 0 && num(r.weight) ? `${Math.round((Number(r.weight) / total) * 1000) / 10}%` : ''}</span></td>
              <td className="num small">{basis && p ? dollars(prizeCost(p, basis, cap)) : ''}</td>
              <td><button type="button" className="btn btn--quiet btn--sm" onClick={() => setRows((x) => x.filter((_, j) => j !== i))}>Remove</button></td>
            </tr>);
          })}</tbody></table></div>
        {rows.length < 8 && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setRows((x) => [...x, { kind: 'percent', value: '5', min_days: '', cap: '', weight: '1' }])}>Add a prize</button>}
        {basis && cost !== null && <p className="small" role="status" data-testid="game-expected-cost"><b>Expected cost per claimed code: {dollars(Math.round(cost))}</b>{' '}
          on the average booking ({dollars(basis.charge_cents)} rental charge, {basis.days} days{basis.source === 'bookings' ? `, from ${basis.bookings} bookings of the last 180 days` : ', from the cars\' daily rates for 4 days until there are 5 bookings'}). A code costs nothing until it is used on a booking.</p>}
      </fieldset>
      <fieldset className="stack-sm"><legend className="d4">Games</legend>
        <p className="small muted">Each visitor gets a game at random, then one they have not seen each time it comes back. Equal numbers give equal chances; 0 turns a game off.</p>
        <div className="ad-cols ad-cols--3">{GAMES.map(([k, l]) => <label key={k} className="field" htmlFor={`${idp}-g${k}`}><span className="label">{l}</span>
          <input className="input" id={`${idp}-g${k}`} inputMode="decimal" value={w[k]} onChange={(e) => setW((x) => ({ ...x, [k]: e.target.value }))} /></label>)}</div>
      </fieldset>
      <div><button type="submit" className="btn btn--primary" disabled={pending}>{pending ? 'Saving' : 'Save prizes and games'}</button></div>
      {msg && <p className={msg.ok ? 'small' : 'small ad-err'} role="status">{msg.text}</p>}
    </form>
  );
}
