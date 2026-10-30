import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { Card, PageHead, Tiles, t, label } from '@/features/admin/ui';
import { HandoversToday } from '@/features/handover/HandoversToday';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { door } from '@/server/door';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Today at a glance', path: '/staff/today', noindex: true, description: 'The day at a glance.' });

type Digest = { open: number; overdue: number; due_today: number; escalated: number; done_today: number; mine: number; by_type: Record<string, number>; pickups_today: number; returns_today: number;
  requests_waiting: number | null; payments_failed: number | null; next: Array<{ title: string; due_at: string }> };

// The digest of today (05-va.md section 1): what is open, late, due and done, and what comes next.
export default async function Today() {
  const { read, fn, user, aal } = await vaPage('/staff/today');
  const [d, drafts] = await Promise.all([read<Digest>('digest'), door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }, aal).catch(() => [] as DraftRow[])]);
  return (
    <>
      <PageHead title="Today at a glance" kicker={FN_LABEL[fn]} purpose="Your open tasks in numbers, today's pickups and returns, and what comes next." />
      <div data-testid="digest"><Tiles items={[
        { k: 'Open', v: d.open, href: '/staff' }, { k: 'Overdue', v: d.overdue, warn: d.overdue > 0, href: '/staff?only=overdue' }, { k: 'Due today', v: d.due_today, href: '/staff?only=today' },
        { k: 'Escalated', v: d.escalated, href: '/staff?only=escalated' }, { k: 'Mine', v: d.mine, href: '/staff?tab=mine' }, { k: 'Done today', v: d.done_today },
        { k: 'Pickups today', v: d.pickups_today }, { k: 'Returns today', v: d.returns_today },
        ...(d.requests_waiting !== null ? [{ k: 'Requests waiting', v: d.requests_waiting, href: '/staff/requests', warn: d.requests_waiting > 0 }] : []),
        ...(d.payments_failed !== null ? [{ k: 'Payments failed (30 days)', v: d.payments_failed, href: '/staff/money', warn: d.payments_failed > 0 }] : [])]} /></div>
      <UnfinishedRentals rows={drafts} base="/staff" />
      <div className="ad-cols ad-cols--2">
        {fn !== 'finance' && <HandoversToday userId={user.id} aal={aal} base="/staff" />}
        <Card title="Open by type">{Object.keys(d.by_type).length ? <ul className="ad-list">{Object.entries(d.by_type).map(([k, n]) => <li key={k}><Link prefetch={false} className="link" href={`/staff?type=${k}`}>{label(k)}</Link><span className="ad-sub">{n}</span></li>)}</ul> : <p className="small muted">Queue clear.</p>}</Card>
        <Card title="Coming next">{d.next.length ? <ul className="ad-list">{d.next.map((x, i) => <li key={i}><span>{x.title}</span><span className="ad-sub">{t(x.due_at)}</span></li>)}</ul> : <p className="small muted">Nothing scheduled.</p>}</Card>
      </div>
    </>
  );
}
