import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { HandoversToday } from '@/features/handover/HandoversToday';
import { door } from '@/server/door';
import { BookingLink, Card, PageHead, t } from '@/features/admin/ui';
import { Prompts } from '@/features/admin/todo/Prompts';
import type { Todo } from '@/features/admin/todo/types';
import { UsageCards } from '@/features/usage/UsageCards';
import { More } from '@/features/portal/Chrome';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'To do', path: '/admin', noindex: true, description: 'What needs an Admin now, in order.' });

interface Health {
  enabled: boolean; interval: number; alert_email: string;
  rules?: { page_minutes: number; email_minutes: number; stripe_minutes: number; max_emails: number; quiet_from: number; quiet_until: number; quiet_outage_minutes: number; emailed_today: number };
  checks: Array<{ key: string; label: string; kind: string; status: 'ok' | 'failing' | 'unknown' | 'waiting'; checked_at: string | null; ok_at: string | null; detail: string | null; failures: number; day: { checks: number; failed: number } }>;
  open: Array<{ id: string; label: string; opened_at: string; detail: string | null; emailed: boolean; real?: boolean; held?: string | null; advice: string }>;
  recent: Array<{ label: string; opened_at: string; resolved_at: string; detail: string | null }>;
  // text alerts (0096): texts a day from the CarmaCars number
  sms?: { days: Array<{ day: string; sent: number; alerts: number; failed: number; skipped: number; codes: number }>; waiting_quiet: number; queued_due: number; opted_out: number; quiet_from: number; quiet_until: number };
}

// The home page (the owner's request of October 16, 2026): one list of what needs you, most urgent first. Each piece of
// work is a prompt that says what to do and why, with a pop-up that does it in place (0078); then the counts with one
// button each; then today's pickups and returns. Everything else is one tap away in the
// menu (the money, fleet and queue figures are under Today > Overview).
export default async function AdminToDo() {
  const { user } = await page('/admin');
  const d = await door<Todo>(user.id, 'ops_read', 'admin_todo');
  const h = await door<Health>(user.id, 'admin_read', 'site_health').catch(() => null);
  // the guided prompts (0078): each piece of work on its own line with its pop-up; the counts below are what has no
  // prompt of its own (a count whose records each have a prompt is not repeated)
  const prompts = d.prompts ?? [];
  const covered = new Set(['applications', 'requests', 'changes', 'plates', 'samples', 'first_last_decide', 'signed_copy_failed']);
  const rest = d.items.filter((i) => !covered.has(i.key));
  const open = rest.filter((i) => i.count > 0);
  const clear = rest.filter((i) => i.count === 0);
  const time = (iso: string) => t(iso).split(', ').pop();
  return (
    <>
      <PageHead title="To do" kicker={prompts.length + open.length ? `${prompts.length + open.reduce((n, i) => n + i.count, 0)} things need you` : 'Nothing needs you right now'}
        purpose="What needs an Admin now, most urgent first. Each line has one button that does it.">
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/overview">Overview</Link>
      </PageHead>
      <UsageCards userId={user.id} />
      <section className="pt-card ad-card" aria-labelledby="todo-h" data-testid="todo-list">
        <h2 className="vh" id="todo-h">To do, most urgent first</h2>
        <Prompts prompts={prompts} />
        {open.length ? (
          <ol className="todo">{open.map((i) => (
            <li key={i.key} className="todo__item" data-testid={`todo-${i.key}`}>
              <span className="todo__count num" data-count>{i.count}</span>
              <span className="todo__label">{i.label}</span>
              <Link prefetch={false} className="btn btn--primary btn--sm" href={i.href}>{i.button}</Link>
            </li>))}
          </ol>
        ) : prompts.length ? null : <p className="ad-empty" data-testid="todo-empty">All clear. New requests, applications and anything that needs you will show up here.</p>}
        {clear.length > 0 && <details className="todo__clear"><summary className="small muted">{clear.length} more with nothing waiting</summary>
          <ul className="small muted">{clear.map((i) => <li key={i.key}><Link prefetch={false} className="link" href={i.href}>{i.label}</Link>: none</li>)}</ul></details>}
      </section>
      <div className="ad-cols ad-cols--2">
        <HandoversToday userId={user.id} base="/admin" />
        <Card title={`Pickups today (${d.pickups.length})`} testId="todo-pickups" aside={<Link prefetch={false} className="link small" href="/admin/calendar">Calendar</Link>}>
          {d.pickups.length ? <ul className="ad-list">{d.pickups.map((r) => (
            <li key={r.booking_number}><span>{time(r.at)} <BookingLink n={r.booking_number} /> {r.renter}</span><span className={r.ready ? 'small' : 'small ad-late'}>{r.ready ? 'ready' : 'not ready'}</span>
              <span className="ad-sub">{r.vehicle}</span></li>))}</ul>
            : <p className="small muted">No pickups today.</p>}
        </Card>
        <Card title={`Returns today (${d.returns.length})`} testId="todo-returns" tone={d.late ? 'warn' : undefined}>
          {d.returns.length ? <ul className="ad-list">{d.returns.map((r) => (
            <li key={r.booking_number}><span>{time(r.at)} <BookingLink n={r.booking_number} /> {r.renter}</span><span className={r.late ? 'small ad-late' : 'small'}>{r.late ? 'late' : 'due'}</span>
              <span className="ad-sub">{r.vehicle}</span></li>))}</ul>
            : <p className="small muted">No returns today.</p>}
          {d.late > 0 && <p className="small"><Link prefetch={false} className="link" href="/admin/bookings?status=on_rent">{d.late} car{d.late > 1 ? 's' : ''} late now</Link></p>}
        </Card>
        {/* 0093: the chauffeur bookings confirmed for today */}
        <Card title={`Chauffeur today (${d.chauffeur_today?.length ?? 0})`} testId="todo-chauffeur" aside={<Link prefetch={false} className="link small" href="/admin/chauffeur">Chauffeur</Link>}>
          {d.chauffeur_today?.length ? <ul className="ad-list">{d.chauffeur_today.map((r) => (
            <li key={r.reference}><span>{r.start_time} {r.reference} {r.name}</span><span className="small">{r.hours} hours</span><span className="ad-sub">{r.vehicle}</span></li>))}</ul>
            : <p className="small muted">No chauffeur bookings today.</p>}
        </Card>
      </div>
      {h && <SiteHealth h={h} />}
    </>
  );
}

// Site health (migrations 0062, 0063): the site check's last result for each page and service, open problems with what
// to do, and the last week's resolved ones. The check runs from the database every few minutes. Only a real outage
// emails (the rules line); short problems such as an Error 1102 show here and in the morning digest.
const hourWords = (h: number) => (h === 0 ? 'midnight' : h === 12 ? 'noon' : h < 12 ? `${h} am` : `${h - 12} pm`);
function SiteHealth({ h }: { h: Health }) {
  const failing = h.checks.filter((c) => c.status === 'failing').length;
  const words = (s: string) => (s === 'ok' ? 'Working' : s === 'failing' ? 'Problem' : s === 'waiting' ? 'Waiting for the website deploy' : 'Not checked yet');
  const r = h.rules;
  return (
    <Card id="site-health" title={failing ? `Site health: ${failing} problem${failing > 1 ? 's' : ''}` : 'Site health'} testId="site-health" tone={failing ? 'warn' : undefined}
      aside={<span className="small muted">{h.enabled ? `Checked every ${h.interval} minutes. Alerts go to ${h.alert_email}` : 'The site check is off (Program settings)'}</span>}>
      {/* portal cleanup (October 23, 2026): every check in one line while nothing is wrong; the details one tap away */}
      {!failing && !h.open.length && <p className="small" data-testid="site-health-summary">{h.checks.every((c) => c.status === 'ok') ? `All ${h.checks.length} checks working.` : h.checks.some((c) => c.status === 'ok') ? `${h.checks.filter((c) => c.status === 'ok').length} of ${h.checks.length} checks working; the others are not checked yet.` : 'Not checked yet.'}</p>}
      {h.open.length > 0 && (
        <ul className="ad-list" data-testid="site-alerts">{h.open.map((a) => (
          <li key={a.id}><span><b>{a.label}</b>: {a.detail} <span className="small muted">since {t(a.opened_at)}{a.emailed ? ', emailed' : a.held ? `, not emailed: ${a.held}` : a.real ? '' : ', short problem: not emailed'}</span></span>
            <span className="ad-sub">{a.advice}</span></li>))}</ul>
      )}
      <More summary={failing || h.open.length ? 'Every check' : 'Every check, the alert rules and texts'} open={!!failing} testId="site-health-more">
      <ul className="sh-list">{h.checks.map((c) => (
        <li key={c.key} data-testid={`check-${c.key}`} data-status={c.status}>
          <span className={`sh-dot is-${c.status}`} aria-hidden="true" />
          <span>{c.label}</span>
          <span className={c.status === 'failing' ? 'small ad-late' : 'small'} data-testid={`check-${c.key}-words`}>{words(c.status)}</span>
          <span className="ad-sub">{c.detail ?? ''}{c.checked_at ? ` · ${t(c.checked_at)}` : ''}{c.day.checks ? ` · ${c.day.failed} of ${c.day.checks} checks failed in 24 hours` : ''}</span>
        </li>))}</ul>
      {r && <p className="small muted" data-testid="site-health-rules">Emails only for a real outage: a page down {r.page_minutes} minutes, emails failing {r.email_minutes} minutes, Stripe failing {r.stripe_minutes} minutes, or the backup failing.
        At most {r.max_emails} a day ({r.emailed_today} today), none from {hourWords(r.quiet_from)} to {hourWords(r.quiet_until)} unless the site is down over {r.quiet_outage_minutes} minutes. Short problems go in the morning digest.</p>}
      {h.sms && <SmsVolume s={h.sms} />}
      {h.recent.length > 0 && <details className="todo__clear"><summary className="small muted">{h.recent.length} resolved in the last 7 days</summary>
        <ul className="small muted">{h.recent.map((r, i) => <li key={i}>{r.label}: {r.detail} ({t(r.opened_at)} to {t(r.resolved_at)})</li>)}</ul></details>}
      </More>
    </Card>
  );
}

// Texts a day (migration 0096): sent (and how many were notifications), failed, not sent (STOP, the US gate, a changed
// choice) and sign-in codes, the last 7 Toronto days; texts waiting for the quiet hours to end.
const dayWords = (iso: string) => new Intl.DateTimeFormat('en-CA', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso}T12:00:00Z`));
function SmsVolume({ s }: { s: NonNullable<Health['sms']> }) {
  const today = s.days[0];
  return (
    <details className="todo__clear" data-testid="sms-volume">
      <summary className="small">Texts today: {today ? `${today.sent} sent${today.failed ? `, ${today.failed} failed` : ''}, ${today.codes} sign-in codes` : 'none'}{s.waiting_quiet ? `; ${s.waiting_quiet} waiting for ${hourWords(s.quiet_until)}` : ''}</summary>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Texts a day">
        <table className="ad-table ad-table--dense"><thead><tr><th scope="col">Day</th><th scope="col" className="num">Sent</th><th scope="col" className="num">Alerts</th><th scope="col" className="num">Failed</th><th scope="col" className="num">Not sent</th><th scope="col" className="num">Sign-in codes</th></tr></thead>
          <tbody>{s.days.map((d) => <tr key={d.day}><td>{dayWords(d.day)}</td><td className="num">{d.sent}</td><td className="num">{d.alerts}</td><td className="num">{d.failed}</td><td className="num">{d.skipped}</td><td className="num">{d.codes}</td></tr>)}</tbody></table>
      </div>
      <p className="small muted">Not sent: the number replied STOP ({s.opted_out} numbers now), a US number before A2P 10DLC, or the person chose email meanwhile; their email went instead. Quiet hours {hourWords(s.quiet_from)} to {hourWords(s.quiet_until)}.</p>
    </details>
  );
}
