import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHeader, SegTabs } from '@/components/ui';
import { Badge, Card, Kv, Table } from '@/features/admin/ui';
import { PrepareProgress } from '@/features/field-portal/PrepareProgress';
import { readinessLines, readinessSummary } from '@/features/booking-page/readiness';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Style guide', path: '/admin/style-guide', noindex: true, description: 'Every shared component of the portals, as the pages draw them.' });

// r35 UX: the style guide, live (docs/style-guide.md). Every shared component as the portals draw it, from the same
// components and the same sheet (styles/ui-kit.css), with made-up sample data. Admins only.
export default async function StyleGuide({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [, sp] = await Promise.all([page('/admin/style-guide'), searchParams]);
  const tab = sp.tab === 'b' ? '/admin/style-guide?tab=b' : '/admin/style-guide';
  const rows = [{ id: '1', number: 'CC-10001', car: '2024 Kia K5', status: 'confirmed', total: '$540.00' }, { id: '2', number: 'CC-10002', car: '2023 Toyota RAV4', status: 'pending_payment', total: '$812.50' }];
  const ready = readinessLines({ status: 'confirmed', dueCents: 54000, paidCents: 54000, insurerBilled: false, readiness: { all_drivers_verified: true, coverage_confirmed: false, deposit_ok: true, agreement_completed: false }, addons: { total: 2, ticked: 1 } });
  return (
    <div className="stack" data-testid="style-guide">
      <PageHeader title="Style guide" lead="Every shared component, as the portals draw it. The rules are in docs/style-guide.md; the sheet is styles/ui-kit.css."
        actions={<><button type="button" className="btn btn--ghost btn--sm">Secondary</button><button type="button" className="btn btn--primary btn--sm">Primary</button></>}
        tabs={<SegTabs label="Sample tabs" current={tab} items={[{ href: '/admin/style-guide', label: 'First tab', count: 3 }, { href: '/admin/style-guide?tab=b', label: 'Second tab' }]} />} />
      <Card title="Buttons">
        <p className="small muted">One shape everywhere: the pill. Primary (red) is the one main action of a screen; black is a firm action; ghost is secondary; quiet sits in a row of text.</p>
        <div className="ad-actions">
          <button type="button" className="btn btn--primary">Primary</button><button type="button" className="btn">Black</button>
          <button type="button" className="btn btn--ghost">Ghost</button><button type="button" className="btn btn--quiet">Quiet</button>
          <button type="button" className="btn btn--primary btn--sm">Small</button><button type="button" className="btn btn--sm" disabled>Disabled</button>
        </div>
      </Card>
      <Card title="Tabs and filter chips">
        <p className="small muted">Tabs move between parts of a page (each has an address). Chips filter a list.</p>
        <SegTabs label="Example sections" current="/admin/style-guide" items={[{ href: '/admin/style-guide', label: 'Overview' }, { href: '/admin/style-guide?tab=b', label: 'Money', count: 2 }, { href: '/admin/style-guide?tab=c', label: 'Documents' }]} />
        <nav className="ad-filters" aria-label="Example filters"><a href="#all" aria-current="page">All</a><a href="#out">Out now</a><a href="#booked">Booked</a></nav>
      </Card>
      <div className="ad-cols ad-cols--2">
        <Card title="Status badges" aside={<span className="pt__count">4</span>}>
          <p className="ad-actions">{['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent', 'returned', 'cancelled'].map((s) => <Badge key={s} s={s} />)}</p>
          <p className="small muted">A badge always says its word: colour is never the only signal.</p>
        </Card>
        <Card title="Details"><Kv rows={[['Pickup', 'Nov 12, 10:00 am'], ['Return', 'Nov 15, 10:00 am'], ['Renter', 'Sam Example']]} /></Card>
      </div>
      <Card title="Table"><Table rows={rows} cols={[{ key: 'number', label: 'Booking' }, { key: 'car', label: 'Car' }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'total', label: 'Total', num: true }]} /></Card>
      <Card title="Empty state"><Table rows={[] as Array<Record<string, unknown>>} cols={[{ key: 'x', label: 'x' }]} empty="Nothing waiting. New requests show here." /></Card>
      <Card title="Checklist" aside={<span className="small">{readinessSummary(ready)}</span>}>
        <ul className="ready-list">{ready.map((l) => <li key={l.key} className={l.done ? 'is-done' : ''}><span className="ready-list__mark" aria-hidden="true">{l.done ? '✓' : ''}</span><span><b>{l.label}</b>{!l.done && <small className="muted"> {l.hint}</small>}</span></li>)}</ul>
      </Card>
      <PrepareProgress d={{ booking_id: 'x', booking_number: 'CC-10001', status: 'confirmed', pickup_at: '2026-11-12T15:00:00Z', total: 2, ticked: 1,
        items: [{ id: 'a', name: 'Booster seat', quantity: 2, note: 'Put it in the car (not installed).', ticked: true, ticked_at: '2026-11-12T13:00:00Z', ticked_by: 'Sam Field' },
          { id: 'b', name: 'Phone charger', quantity: 1, note: null, ticked: false, ticked_at: null, ticked_by: null }],
        job: { id: 'j', kind: 'delivery', status: 'in_progress', scheduled_at: '2026-11-12T14:00:00Z', started_at: null, completed_at: null, who: 'Sam Field' } }} testId="sg-prepare" />
    </div>
  );
}
