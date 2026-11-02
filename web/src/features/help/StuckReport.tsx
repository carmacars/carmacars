import { Card, Table, d } from '@/features/admin/ui';

export type StuckReportData = { settings: { on: boolean; idle_minutes: number; errors: number }; shown_30: number;
  pages: Array<{ portal: string; route: string; tab: string | null; shown: number; guide: number; lesson: number; snooze: number; people: number; last: string }> };
const PORTAL: Record<string, string> = { admin: 'Admin', va: 'Staff', field: 'Field work', owner: 'Owner', renter: 'Renter', investor: 'Investor' };

// Settings > Program settings: the pages where people get stuck most (migration 0510), the last 30 days. A page high on this
// list needs a clearer screen or a better guide chapter.
export function StuckReport({ d: r }: { d: StuckReportData | null }) {
  if (!r) return null;
  return (
    <Card title="Where people get stuck" testId="stuck-report">
      <p className="small muted">{r.settings.on ? `The "Stuck?" help shows after ${r.settings.idle_minutes} minutes on a page without a successful action, or ${r.settings.errors} errors, or going back and forth between two steps.` : 'The "Stuck?" help is off (Stuck? help, above).'} It showed {r.shown_30} times in the last 30 days.</p>
      <Table testId="stuck-pages" caption="Pages where the help showed most" empty="No one has needed it yet." rowKey={(x) => `${String(x.route)}-${String(x.tab ?? '')}`}
        rows={r.pages as unknown as Array<Record<string, unknown>>} cols={[
          { key: 'route', label: 'Page', render: (x) => <><b>{String(x.route)}</b>{x.tab ? <span className="muted"> tab {String(x.tab)}</span> : null} <span className="muted">({PORTAL[String(x.portal)] ?? String(x.portal)})</span></> },
          { key: 'shown', label: 'Shown', num: true }, { key: 'people', label: 'People', num: true }, { key: 'guide', label: 'Guide opened', num: true },
          { key: 'lesson', label: 'Lesson opened', num: true }, { key: 'last', label: 'Last', render: (x) => d(String(x.last)) }]} />
    </Card>);
}
