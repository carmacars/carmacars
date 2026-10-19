import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { BookingLink, Card, PageHead, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'To do', path: '/admin', noindex: true, description: 'What needs an Admin now, in order.' });

interface Health {
  enabled: boolean; interval: number; alert_email: string;
  checks: Array<{ key: string; label: string; kind: string; status: 'ok' | 'failing' | 'unknown'; checked_at: string | null; ok_at: string | null; detail: string | null; failures: number; day: { checks: number; failed: number } }>;
  open: Array<{ id: string; label: string; opened_at: string; detail: string | null; emailed: boolean; advice: string }>;
  recent: Array<{ label: string; opened_at: string; resolved_at: string; detail: string | null }>;
}

interface Todo {
  items: Array<{ key: string; label: string; button: string; href: string; count: number }>;
  pickups: Array<{ booking_number: string; at: string; vehicle: string; renter: string; ready: boolean }>;
  returns: Array<{ booking_number: string; at: string; vehicle: string; renter: string; late: boolean }>;
  late: number;
}

// The home page (the owner's request of October 16, 2026): one list of what needs you, most urgent first, each with
// its count and one button to deal with it; then today's pickups and returns. Everything else is one tap away in the
// menu (the money, fleet and queue figures are under Today > Overview).
export default async function AdminToDo() {
  const { user } = await page('/admin');
  const d = await door<Todo>(user.id, 'ops_read', 'admin_todo');
  const h = await door<Health>(user.id, 'admin_read', 'site_health').catch(() => null);
  const open = d.items.filter((i) => i.count > 0);
  const clear = d.items.filter((i) => i.count === 0);
  const time = (iso: string) => t(iso).split(', ').pop();
  return (
    <>
      <PageHead title="To do" kicker={open.length ? `${open.reduce((n, i) => n + i.count, 0)} things need you` : 'Nothing needs you right now'}>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/overview">Overview</Link>
      </PageHead>
      <section className="pt-card ad-card" aria-labelledby="todo-h" data-testid="todo-list">
        <h2 className="vh" id="todo-h">To do, most urgent first</h2>
        {open.length ? (
          <ol className="todo">{open.map((i) => (
            <li key={i.key} className="todo__item" data-testid={`todo-${i.key}`}>
              <span className="todo__count num">{i.count}</span>
              <span className="todo__label">{i.label}</span>
              <Link prefetch={false} className="btn btn--primary btn--sm" href={i.href}>{i.button}</Link>
            </li>))}
          </ol>
        ) : <p className="ad-empty" data-testid="todo-empty">All clear. New requests, applications and anything that needs you will show up here.</p>}
        {clear.length > 0 && <details className="todo__clear"><summary className="small muted">{clear.length} more with nothing waiting</summary>
          <ul className="small muted">{clear.map((i) => <li key={i.key}><Link prefetch={false} className="link" href={i.href}>{i.label}</Link>: none</li>)}</ul></details>}
      </section>
      <div className="ad-cols ad-cols--2">
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
      </div>
      {h && <SiteHealth h={h} />}
    </>
  );
}

// Site health (migration 0062): the site check's last result for each page and service, open problems with what to
// do, and the last week's resolved ones. The check runs from the database every few minutes.
function SiteHealth({ h }: { h: Health }) {
  const failing = h.checks.filter((c) => c.status === 'failing').length;
  const words = (s: string) => (s === 'ok' ? 'Working' : s === 'failing' ? 'Problem' : 'Not checked yet');
  return (
    <Card id="site-health" title={failing ? `Site health: ${failing} problem${failing > 1 ? 's' : ''}` : 'Site health'} testId="site-health" tone={failing ? 'warn' : undefined}
      aside={<span className="small muted">{h.enabled ? `Checked every ${h.interval} minutes. Alerts go to ${h.alert_email}` : 'The site check is off (Program settings)'}</span>}>
      {h.open.length > 0 && (
        <ul className="ad-list" data-testid="site-alerts">{h.open.map((a) => (
          <li key={a.id}><span><b>{a.label}</b>: {a.detail} <span className="small muted">since {t(a.opened_at)}{a.emailed ? ', emailed' : ''}</span></span>
            <span className="ad-sub">{a.advice}</span></li>))}</ul>
      )}
      <ul className="sh-list">{h.checks.map((c) => (
        <li key={c.key} data-testid={`check-${c.key}`} data-status={c.status}>
          <span className={`sh-dot is-${c.status}`} aria-hidden="true" />
          <span>{c.label}</span>
          <span className={c.status === 'failing' ? 'small ad-late' : 'small'}>{words(c.status)}</span>
          <span className="ad-sub">{c.detail ?? ''}{c.checked_at ? ` · ${t(c.checked_at)}` : ''}{c.day.checks ? ` · ${c.day.failed} of ${c.day.checks} checks failed in 24 hours` : ''}</span>
        </li>))}</ul>
      {h.recent.length > 0 && <details className="todo__clear"><summary className="small muted">{h.recent.length} resolved in the last 7 days</summary>
        <ul className="small muted">{h.recent.map((r, i) => <li key={i}>{r.label}: {r.detail} ({t(r.opened_at)} to {t(r.resolved_at)})</li>)}</ul></details>}
    </Card>
  );
}
