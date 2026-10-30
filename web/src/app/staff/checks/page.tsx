import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { DailyCheck, type Item } from '@/features/va/DailyCheck';
import { Card, PageHead, Tabs, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Daily checks', path: '/staff/checks', noindex: true, description: 'The opening and closing checks.' });

type Form = { date: string; kind: 'opening' | 'closing'; due: string; items: Item[]; saved: { items: Record<string, { result: string; note?: string }>; completed_at: string; completed_by: string | null; issues: string | null } | null };

// The daily checks (procedure 19; 05-va.md section 3.5, /va/fleet/checks): opening by 9:00, closing by 18:00.
export default async function Checks({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const kind = sp.kind === 'closing' ? 'closing' : 'opening';
  const { read } = await vaPage('/staff/checks', ['fleet']);
  const f = await read<Form>('daily_check', { kind });
  return (<>
    <PageHead title="Daily checks" kicker={`Due by ${t(f.due)}`} />
    <Tabs current={`/staff/checks?kind=${kind}`} items={[['/staff/checks?kind=opening', 'Opening'], ['/staff/checks?kind=closing', 'Closing']]} />
    {f.saved && <p className="alert alert--ok" role="status"><span className="alert__title">Done</span><span>Saved {t(f.saved.completed_at)}{f.saved.completed_by ? ` by ${f.saved.completed_by}` : ''}. You can save it again.</span></p>}
    <Card title={kind === 'opening' ? 'Opening check' : 'Closing check'}><DailyCheck key={kind} kind={kind} date={f.date} items={f.items} saved={f.saved?.items ?? null} /></Card>
  </>);
}
