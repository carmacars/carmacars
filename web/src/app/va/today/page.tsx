import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { Card, PageHead, Tiles, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Today at a glance', path: '/va/today', noindex: true, description: 'The day at a glance.' });

type Digest = { open: number; overdue: number; due_today: number; escalated: number; done_today: number; mine: number; by_type: Record<string, number>; pickups_today: number; returns_today: number;
  requests_waiting: number | null; payments_failed: number | null; next: Array<{ title: string; due_at: string }> };

// The digest of today (05-va.md section 1): what is open, late, due and done, and what comes next.
export default async function Today() {
  const { read, fn } = await vaPage('/va/today');
  const d = await read<Digest>('digest');
  return (
    <>
      <PageHead title="Today at a glance" kicker={FN_LABEL[fn]} purpose="Your open tasks in numbers, today's pickups and returns, and what comes next." />
      <div data-testid="digest"><Tiles items={[
        { k: 'Open', v: d.open, href: '/va' }, { k: 'Overdue', v: d.overdue, warn: d.overdue > 0, href: '/va?only=overdue' }, { k: 'Due today', v: d.due_today, href: '/va?only=today' },
        { k: 'Escalated', v: d.escalated, href: '/va?only=escalated' }, { k: 'Mine', v: d.mine, href: '/va?tab=mine' }, { k: 'Done today', v: d.done_today },
        { k: 'Pickups today', v: d.pickups_today }, { k: 'Returns today', v: d.returns_today },
        ...(d.requests_waiting !== null ? [{ k: 'Requests waiting', v: d.requests_waiting, href: '/va/requests', warn: d.requests_waiting > 0 }] : []),
        ...(d.payments_failed !== null ? [{ k: 'Payments failed (30 days)', v: d.payments_failed, href: '/va/money', warn: d.payments_failed > 0 }] : [])]} /></div>
      <div className="ad-cols ad-cols--2">
        <Card title="Open by type">{Object.keys(d.by_type).length ? <ul className="ad-list">{Object.entries(d.by_type).map(([k, n]) => <li key={k}><Link prefetch={false} className="link" href={`/va?type=${k}`}>{label(k)}</Link><span className="ad-sub">{n}</span></li>)}</ul> : <p className="small muted">Queue clear.</p>}</Card>
        <Card title="Coming next">{d.next.length ? <ul className="ad-list">{d.next.map((x, i) => <li key={i}><span>{x.title}</span><span className="ad-sub">{t(x.due_at)}</span></li>)}</ul> : <p className="small muted">Nothing scheduled.</p>}</Card>
      </div>
    </>
  );
}
