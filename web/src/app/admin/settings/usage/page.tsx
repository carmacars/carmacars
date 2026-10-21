import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card, PageHead, t, d } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { UsageAllow } from '@/features/usage/UsageAllow';
import { paidCost, share, shortLabel, usd, type ServiceState } from '@/features/usage/model';
import { UsageChart } from '@/features/usage/UsageChart';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Usage', path: '/admin/settings/usage', noindex: true, description: 'Included allowances of every metered service, what is used, and paid usage.' });

type Row = ServiceState & { history: Array<{ day: string; used: number }>; decisions: Array<{ decision: string; until: string; starts_on: string; ends_on: string; cap_usd: number | null; at: string; by: string | null }> };
interface Data { services: Row[]; alerts: Array<{ service: string; level: number; period_start: string; at: string; emailed_at: string | null; email_note: string | null }>; alert_email: string; cloudflare_at: string | null }

const STATE: Record<string, string> = { ok: 'Within the allowance', warn: 'Near the allowance', paused: 'Used up: paused', paid: 'Used up: paid usage allowed', held: 'Used up: held', over: 'Used up: never paused, small cost', free: 'Free', used_up: 'Used up' };

// Settings > Usage (migration 0080): each metered service, what is used against what the plan includes, when it resets,
// whether paid usage is allowed and up to how much, and the last 30 days.
export default async function UsagePage() {
  const { read } = await page('/admin/settings/usage');
  const u = await read<Data>('usage');
  const bytes = (s: Row) => s.unit === 'bytes';
  return (
    <>
      <PageHead title="Usage" kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} />
      <p className="small muted" style={{ maxWidth: '52rem' }} data-testid="usage-intro">What the plans include and what is used. When an allowance runs out, AI and photo features pause with a short message until it resets, unless you allow paid usage up to an amount. The website, the portals, the database and storage are never paused: they alert at 80% and when used up, with the estimated cost.
        Alerts go to {u.alert_email} (once per service and period, never at night). Cloudflare figures: {u.cloudflare_at ? `last reported ${t(u.cloudflare_at)}` : 'not reported yet (the usage workflow sends them every hour)'}.</p>
      {u.services.map((s) => {
        const cost = paidCost(s);
        return (
          <Card key={s.service} id={`usage-${s.service}`} title={shortLabel(s.label)} testId={`usage-${s.service}`} tone={s.state === 'paused' || s.state === 'held' ? 'warn' : undefined}
            aside={<span className={`small${s.state === 'paused' || s.state === 'held' ? ' ad-late' : ''}`} data-testid={`usage-${s.service}-state`}>{STATE[s.state] ?? s.state}</span>}>
            {!s.unlimited && (
              <div className="ug-meter" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.min(100, Math.round(s.share_bps / 100))} aria-label={`${shortLabel(s.label)}: ${share(s.share_bps)} of the included allowance`}>
                <span className={`ug-meter__bar${s.share_bps >= 10000 ? ' is-over' : s.share_bps >= s.warn_bps ? ' is-warn' : ''}`} style={{ width: `${Math.min(100, s.share_bps / 100)}%` }} />
              </div>)}
            <dl className="pt-dl ad-kv">
              <div><dt>Used</dt><dd data-testid={`usage-${s.service}-used`}>{s.used_text} of {s.included_text}{s.unlimited ? '' : ` (${share(s.share_bps)})`}</dd></div>
              <div><dt>Period</dt><dd>{s.period === 'day' ? 'Each day, Toronto time' : s.period === 'month' ? 'Each month' : 'A size (no reset)'}{s.resets_at ? `. Resets ${t(s.resets_at)}` : ''}</dd></div>
              <div><dt>Paid usage</dt><dd data-testid={`usage-${s.service}-paid`}>{s.pause_mode === 'pause'
                ? (s.decision?.decision === 'allow' ? `Allowed until ${d(s.decision.ends_on)}, up to ${usd(s.decision.cap_usd)} (${usd(s.decision.spent_usd)} used)` : s.decision?.decision === 'keep_paused' ? 'Kept paused' : 'Not allowed: paused when used up (you are asked first)')
                : s.pause_mode === 'hold' ? 'Not possible on the free plan' : 'Never paused (would stop bookings): billed at the rate below'}</dd></div>
              <div><dt>Rate</dt><dd>{s.upgrade_text && s.pause_mode !== 'pause' ? `${s.price_text} ${s.upgrade_text}` : s.price_text}{s.overage_usd > 0 ? ` Above the allowance so far: ${usd(s.overage_usd)}.` : ''}</dd></div>
              <div><dt>When used up</dt><dd>{s.when_used_up}</dd></div>
              <div><dt>Measured by</dt><dd>{s.measured_by}{s.measured_at ? ` Last figure ${t(s.measured_at)}.` : ' No figure yet.'}</dd></div>
            </dl>
            {!s.unlimited && <UsageChart s={s} history={s.history} />}
            <div className="row">
              {s.pause_mode === 'pause' && cost.canPay && <UsageAllow s={s} testId={`usage-page-allow-${s.service}`} />}
              {!s.unlimited && <Act action="usage_service_save" label="Change the allowance" title={`${shortLabel(s.label)}: the included allowance`} testId={`usage-edit-${s.service}`}
                payload={{ service: s.service }} refresh={['/admin/settings/usage']} done="Saved."
                fields={[bytes(s) ? { name: 'included_mb', label: 'Included (MB)', type: 'number', min: 0, value: Math.round(s.included / 1048576), required: true }
                                 : { name: 'included', label: `Included (${s.unit === 'microusd' ? 'micro-dollars' : s.unit.replace('_', ' ')})`, type: 'number', min: 0, value: s.included, required: true },
                         { name: 'warn_bps', label: 'Early warning at (%)', type: 'percent', value: s.warn_bps, required: true, hint: '80 sends the quiet alert at 80% of the allowance.' }]} />}
              {(s.service === 'supabase_egress' || s.unit === 'bytes' || s.service === 'workers_requests' || s.service === 'workers_cpu') && (
                <Act action="usage_reading_save" label="Enter a figure" title={`${shortLabel(s.label)}: a figure from the provider's dashboard`} testId={`usage-reading-${s.service}`}
                  payload={{ service: s.service }} refresh={['/admin/settings/usage']} done="Saved."
                  fields={[{ name: 'day', label: 'Day', type: 'date', required: true },
                           bytes(s) ? { name: 'used_mb', label: s.period === 'size' ? 'Size that day (MB)' : 'Used that day (MB)', type: 'number', min: 0, required: true }
                                    : { name: 'used', label: 'Used that day', type: 'number', min: 0, required: true }]} />)}
            </div>
            {s.decisions.length > 0 && <details className="todo__clear"><summary className="small muted">Paid usage answers ({s.decisions.length})</summary>
              <ul className="small muted">{s.decisions.map((x, i) => <li key={i}>{t(x.at)}: {x.decision === 'allow' ? `allowed until ${d(x.ends_on)}, up to ${usd(x.cap_usd)}` : 'kept paused'}{x.by ? `, by ${x.by}` : ''}</li>)}</ul></details>}
          </Card>
        );
      })}
      {u.alerts.length > 0 && (
        <Card title="Recent alerts" testId="usage-alerts">
          <ul className="small">{u.alerts.map((a, i) => <li key={i}>{t(a.at)}: {shortLabel(u.services.find((s) => s.service === a.service)?.label ?? a.service)} at {a.level}%{a.emailed_at ? (a.email_note ? ` (${a.email_note})` : ', emailed') : ', email waiting for the morning'}</li>)}</ul>
        </Card>)}
    </>
  );
}
