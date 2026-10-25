import { Card, t } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';

// Settings > Usage: Workers AI by feature (migration 0133). The day's free neurons are split in tiers: the staff
// assistant keeps its reserve, live features (chat, phone, readers) share what is not reserved, background work gets a
// small share and what is left after the release hour. Each feature's neurons today and over 7 days, the use Cloudflare
// counts that the app did not record, each tier's room now, and the shares an Admin may change. A hard stop: never paid.
export interface AiUsage {
  included: number; used: number; used_app: number; unmetered: number;
  tiers: { assistant: number; live: number; background: number };
  room: { assistant: number; live: number; background: number };
  reserve: number; background_cap: number; cushion: number; late: boolean; reserve_bps: number; background_bps: number; release_hour: number | null; assistant_daily: number;
  resets_at: string; seo_writer?: boolean;
  features: Array<{ purpose: string; label: string; tier: 'assistant' | 'live' | 'background'; today: number; calls_today: number; failed_today: number; week: number; calls_week: number }>;
  days: Array<{ day: string; assistant: number; live: number; background: number; cloudflare: number | null }>;
}

const n = (v: number | null | undefined) => Math.round(Number(v ?? 0)).toLocaleString('en-US');
const TIER: Record<string, string> = { assistant: 'Staff assistant', live: 'Live (someone waiting)', background: 'Background' };
const hour = (h: number | null) => (h === null ? 'never' : `${h === 0 ? 12 : h > 12 ? h - 12 : h}:00 ${h < 12 ? 'am' : 'pm'}`);

export function AiByFeature({ ai }: { ai: AiUsage }) {
  const pct = (bps: number) => `${Math.round(bps / 100)}%`;
  return (
    <Card title="Workers AI by feature" id="usage-ai-features" testId="usage-ai-features"
      aside={<span className="small" data-testid="usage-ai-used">{n(ai.used)} of {n(ai.included)} neurons today</span>}>
      <p className="small" style={{ maxWidth: '52rem' }}>A hard stop at the free allowance, never paid. The staff assistant keeps {pct(ai.reserve_bps)} of the day ({n(ai.reserve)} neurons) for itself and may use anything the others leave.
        Live features (visitor chat, the phone line, the toll reader, the plate finder) share the rest. Background work (search copy, listing copy, guide rewrites, Turo email reading) gets {pct(ai.background_bps)} ({n(ai.background_cap)} neurons)
        {ai.release_hour !== null ? `, and from ${hour(ai.release_hour)} what is left of the day less ${n(ai.cushion)} kept for the assistant` : ''}. Resets {t(ai.resets_at)}.
        {ai.seo_writer === false ? ' Search copy is written by the daily Claude batch, not Workers AI (Program settings: search copy writer off).' : ''}</p>
      <dl className="pt-dl ad-kv" data-testid="usage-ai-room">
        {(['assistant', 'live', 'background'] as const).map((k) => (
          <div key={k}><dt>{TIER[k]}</dt><dd data-testid={`usage-ai-room-${k}`}>{n(ai.tiers[k])} used, {n(ai.room[k])} left now</dd></div>))}
        {ai.unmetered > 0 && <div><dt>Unmetered</dt><dd data-testid="usage-ai-unmetered">{n(ai.unmetered)} counted by Cloudflare beyond the app&apos;s own record (counted as background)</dd></div>}
      </dl>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Workers AI by feature">
        <table className="ad-table ad-table--dense" data-testid="usage-ai-table">
          <thead><tr><th scope="col">Feature</th><th scope="col">Tier</th><th scope="col" className="num">Today</th><th scope="col" className="num">Calls today</th><th scope="col" className="num">Last 7 days</th><th scope="col" className="num">Calls, 7 days</th></tr></thead>
          <tbody>
            {ai.features.length ? ai.features.map((f) => (
              <tr key={f.purpose} data-testid={`usage-ai-row-${f.purpose}`}><td>{f.label}</td><td>{TIER[f.tier]}</td><td className="num">{n(f.today)}</td>
                <td className="num">{n(f.calls_today)}{f.failed_today ? ` (${n(f.failed_today)} failed)` : ''}</td><td className="num">{n(f.week)}</td><td className="num">{n(f.calls_week)}</td></tr>))
              : <tr><td colSpan={6} className="muted">No AI calls in the last 7 days.</td></tr>}
          </tbody>
        </table>
      </div>
      {ai.days.length > 0 && <details className="todo__clear"><summary className="small muted">By day and tier (7 days)</summary>
        <ul className="small muted">{ai.days.map((d) => <li key={d.day}>{d.day}: assistant {n(d.assistant)}, live {n(d.live)}, background {n(d.background)}{d.cloudflare !== null ? `; Cloudflare counted ${n(d.cloudflare)}` : ''}</li>)}</ul></details>}
      <div className="row">
        <Act action="ai_shares_save" label="Change the shares" title="Workers AI: the shares of the day" testId="usage-ai-shares" refresh={['/admin/settings/usage']} done="Saved."
          fields={[
            { name: 'reserve_bps', label: 'Kept for the staff assistant (%)', type: 'percent', value: ai.reserve_bps, required: true, hint: 'Nothing else may use it before the release hour. 70 by default.' },
            { name: 'background_bps', label: 'Background work (%)', type: 'percent', value: ai.background_bps, required: true, hint: 'Search copy, listing copy, guide rewrites, Turo emails. 10 by default.' },
            { name: 'release_hour', label: 'Release hour (0 to 23, Toronto; empty: never)', type: 'number', min: 0, max: 23, value: ai.release_hour ?? '', hint: 'From this hour what is left goes to the others. 21 by default.' },
            { name: 'cushion', label: 'Always kept for the assistant after the release hour (neurons)', type: 'number', min: 0, value: ai.cushion, required: true }]} />
      </div>
    </Card>
  );
}
