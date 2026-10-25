import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { HoursBoard, type PayData } from '@/features/field-pay/HoursBoard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field hours', path: '/va/field-hours', noindex: true, description: 'Field staff hours: fix a forgotten clock-out or enter hours.' });

// Fleet Operations > Field hours (0165): who is clocked in and every shift of the two-week period. Fleet fixes a forgotten clock-out or enters
// hours; each change needs a reason and is logged. Pay and rates are the Admin's.
export default async function FieldHours({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/va/field-hours', ['fleet']), searchParams]);
  const data = await door<PayData>(user.id, 'ops_read', 'field_pay', sp.date ? { date: sp.date } : {}, aal);
  return (<><PageHead title="Field hours" kicker={data.period.label} purpose="Who is clocked in, and the hours of the two-week pay period. Fix a forgotten clock-out or enter hours: say why, and it is written in the log." />
    <HoursBoard data={data} base="/va/field-hours" /></>);
}
