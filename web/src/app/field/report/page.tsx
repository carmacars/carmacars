import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FieldReport } from '@/features/field/FieldReport';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Report', path: '/field/report', noindex: true, description: 'Report something from a car.' });

// /field/report (06-field.md section 9).
export default async function Report() {
  const { user } = await requireStaff('field', '/field/report');
  const f = await door<{ vehicles: Array<{ id: string; name: string; job: string }> }>(user.id, 'field_read', 'report_form');
  return (<><h1 className="d3">Report something</h1><FieldReport vehicles={f.vehicles} /></>);
}
