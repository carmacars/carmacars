import './usage.css';
import Link from '@/components/Link';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { t } from '@/features/admin/ui';
import { CF_EMAIL_STEPS, emailNowLine, emailTodayLine, CF_EMAIL_STEPS_HREF, PAUSE, bannerLine, bannerTone, cfEmailNeedsSetup, cfEmailSentence, noteLine, paidCost, share, shortLabel, usd, usedUpTitle, type BannerRow, type CfEmail, type ServiceState } from './model';
import { UsageAllow } from './UsageAllow';

// The usage guard on Admin > To do (migration 0080): one quiet card at 80% of an included allowance, one card when it is
// used up (with "Allow paid usage" where paying is possible), and a banner while emails are held by the plan's limits.
type CardRow = ServiceState & { alert_id: string; level: 70 | 80 | 100; title: string; emailed_at: string | null; email_note: string | null };
interface Cards { cards: CardRow[]; emails_held: number }

export async function UsageCards({ userId }: { userId: string }) {
  const u = await door<Cards>(userId, 'ops_read', 'usage_cards').catch(() => null);
  if (!u) return null;
  // r35 part C (owner, 2026-11-11): Resend's daily part is never shown as a cap (the capacity line below counts Cloudflare + Resend)
  u.cards = u.cards.filter((c) => c.service !== 'resend_day');
  if (!u.cards.length && !u.emails_held) return null;
  return (
    <div className="stack" data-testid="usage-cards">
      {u.emails_held > 0 && (
        <p className="alert alert--warn" role="status" data-testid="usage-emails-held"><span><b>{u.emails_held} email{u.emails_held === 1 ? '' : 's'} held.</b> {PAUSE.emailsHeld} <Link prefetch={false} className="link" href="/admin/logs?tab=emails">See the emails</Link></span></p>)}
      {u.cards.map((c) => <UsageCard key={c.alert_id} c={c} />)}
    </div>
  );
}

function UsageCard({ c }: { c: CardRow }) {
  const name = shortLabel(c.label);
  const resets = c.resets_at ? `Resets ${t(c.resets_at)}.` : '';
  if (c.level < 100) {
    return (
      <section className="pt-card ad-card" aria-labelledby={`u-${c.alert_id}`} data-testid={`usage-card-${c.service}`} data-level={c.level}>
        <div className="pt-card__head"><h2 className="d4" id={`u-${c.alert_id}`}>{name} at {share(c.share_bps)} of the included allowance</h2>
          <Act action="usage_alert_dismiss" payload={{ id: c.alert_id }} label="Dismiss" variant="quiet" testId={`usage-dismiss-${c.service}`} /></div>
        <p className="small">{c.used_text} of {c.included_text} used. {resets} Nothing changes yet. When it is used up: {c.when_used_up}</p>
      </section>
    );
  }
  const cost = paidCost(c);
  const paid = c.state === 'paid' && c.decision?.decision === 'allow';
  return (
    <section className="pt-card ad-card ad-card--warn" aria-labelledby={`u-${c.alert_id}`} data-testid={`usage-card-${c.service}`} data-level="100" data-state={c.state}>
      <div className="pt-card__head"><h2 className="d4" id={`u-${c.alert_id}`}>{usedUpTitle(c)}{cost.canPay && !paid ? ': Allow paid usage' : ''}</h2></div>
      <p className="small">{c.used_text} of {c.included_text} used. {resets}</p>
      {c.pause_mode === 'alert' ? (
        <p className="small" data-testid={`usage-never-paused-${c.service}`}><b>Never paused:</b> {c.when_used_up} Estimated cost above the allowance so far: <b>{usd(c.overage_usd)}</b>. {c.upgrade_text ?? ''}</p>
      ) : c.pause_mode === 'hold' ? (
        <p className="small"><b>Held:</b> {c.when_used_up} {c.upgrade_text}</p>
      ) : !cost.canPay ? (
        <p className="small" data-testid={`usage-hard-stop-${c.service}`}><b>Stopped for today, never paid.</b> {c.when_used_up}</p>
      ) : paid ? (
        <p className="small" data-testid={`usage-paid-${c.service}`}>Paid usage allowed until the end of {c.decision!.until === 'day' ? 'today' : 'this month'}, up to {usd(c.decision!.cap_usd)} ({usd(c.decision!.spent_usd)} used so far){c.decision!.by ? `, by ${c.decision!.by}` : ''}.</p>
      ) : (
        <>
          <p className="small"><b>{c.decision?.decision === 'keep_paused' ? 'Kept paused.' : 'Paused until you answer.'}</b> {c.when_used_up}</p>
          <p className="small muted">{cost.rate} {cost.example}</p>
        </>
      )}
      {c.pause_mode === 'pause' && !paid && cost.canPay && <UsageAllow s={c} testId={`usage-allow-${c.service}`} />}
      <p className="small"><Link prefetch={false} className="link" href="/admin/settings/usage">Settings &gt; Usage</Link></p>
    </section>
  );
}

// R23 (0221): the banner at the top of Admin > Today for every figure at its warning level or past it this period. 0320:
// in money. Red only for a hard stop or held emails at 100%, or a service billed by use whose projected cost this month
// reaches the Program setting (US$5); a quiet note when it is only cents; the emails' line says whether Cloudflare sends.
export async function UsageBanner({ userId }: { userId: string }) {
  const rows = await door<BannerRow[]>(userId, 'ops_read', 'usage_banner').catch(() => null);
  return rows?.length ? <UsageBannerView rows={rows} /> : null;
}

/** The banner itself, from the rows (pure: the screenshot harness renders it too). */
export function UsageBannerView({ rows: all }: { rows: BannerRow[] }) {
  // r35 part C (owner, 2026-11-11): Resend's daily part is never shown as a cap; the day's capacity is on Settings > Usage
  const rows = all.filter((r) => r.service !== 'resend_day');
  const red = rows.filter((r) => bannerTone(r) === 'red');
  const amber = rows.filter((r) => bannerTone(r) === 'amber');
  const note = rows.filter((r) => bannerTone(r) === 'note');
  const cf = all.find((r) => r.cf)?.cf;
  // r35: Resend's allowance from its usage row (the setting), never a number written here
  const cfLine = cfEmailSentence(cf);
  const emailRow = [...red, ...amber].some((r) => r.service === 'resend_month');
  const settings = <Link prefetch={false} className="link" href="/admin/settings/usage">Settings &gt; Usage</Link>;
  const setup = cfLine && emailRow ? <span className="ug-banner__cf" data-testid="usage-banner-cf">{cfLine} <Link prefetch={false} className="link" href={CF_EMAIL_STEPS_HREF}>{cfEmailNeedsSetup(cf) ? 'The 4 setup steps' : 'Settings > Usage'}</Link></span> : null;
  return (
    <div className="stack" data-testid="usage-banner">
      {red.length > 0 && <p className="alert alert--error" role="alert" data-testid="usage-banner-over"><span className="alert__title">Over the included allowance</span>
        <span>{red.map(bannerLine).join('; ')}. {settings}</span>{red.some((r) => r.service.startsWith('resend')) && setup}</p>}
      {amber.length > 0 && <p className="alert alert--warn" role="status" data-testid="usage-banner-near"><span className="alert__title">Close to the included allowance</span>
        <span>{amber.map(bannerLine).join('; ')}. {settings}</span>{!red.some((r) => r.service.startsWith('resend')) && setup}</p>}
      {note.length > 0 && <p className="small muted ug-note" data-testid="usage-banner-note">Small costs above the allowance: {note.map(noteLine).join('; ')}. Under {usd(note[0]!.red_usd ?? 5)} a month, so no alert. {settings}</p>}
    </div>
  );
}

/** Settings > Usage: whether Cloudflare Email Service sends the outbox, and the exact steps only while it never sent (0320, 1750). */
/** r29 (0583), 1750: today's emails by provider against each one's daily budget, and the month's Cloudflare emails */
export interface EmailPace { day_used: number; cf_today?: number; cf_day_budget?: number; resend_today?: number; resend_day_budget?: number; auth_today?: number; fallback_today?: number;
  hour_used?: number; waiting: number; held?: number; cf_month?: number; cf_included?: number; cf_left?: number; cf_open?: boolean; cf_state?: string; cf_reason?: string | null }
/** 1750: "Today: Cloudflare 25 of 100, Resend 6 of 100. Cloudflare sends (75 left today). This month through Cloudflare: 426 of 3,000." (Admin > Settings > Usage only) */
export function paceLine(p: EmailPace): string {
  return `Today: ${emailTodayLine(p)}. ${emailNowLine(p)}`;
}

export async function EmailSetup({ userId }: { userId: string }) {
  const [c, pace] = await Promise.all([door<CfEmail>(userId, 'ops_read', 'usage_email_setup').catch(() => null), door<EmailPace>(userId, 'ops_read', 'email_pace').catch(() => null)]);
  if (!c) return null;
  const line = cfEmailSentence(c);
  return (
    <section id="email-setup" className={`pt-card ad-card${line ? ' ad-card--warn' : ''}`} aria-labelledby="email-setup-h" data-testid="usage-email-setup" data-state={c.state}>
      <div className="pt-card__head"><h2 className="d4" id="email-setup-h">{line ? 'Emails: Cloudflare Email Service is not sending' : 'Emails: Cloudflare Email Service sends them'}</h2></div>
      {pace && <p className="small" data-testid="usage-email-pace">{paceLine(pace)}</p>}
      {line ? (
        <>
          <p className="small">{line}</p>
          {cfEmailNeedsSetup(c) && <ol className="small ug-steps">{CF_EMAIL_STEPS.map((s) => <li key={s}>{s}</li>)}</ol>}
        </>
      ) : !pace && <p className="small">{c.sent_month.toLocaleString('en-US')} of {c.included.toLocaleString('en-US')} included this month. Resend takes over after Cloudflare&apos;s daily budget, or if Cloudflare refuses an email.</p>}
    </section>
  );
}
