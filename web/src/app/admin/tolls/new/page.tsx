import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Card, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Log a notice', path: '/admin/tolls/new', noindex: true, description: 'Log one toll, ticket or fine.' });
export default async function NewToll() {
  await page('/admin/tolls/new');
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link>} title="Log a notice" />
    <Card title="Save and match"><Act inline action="toll_log" nest="row" label="Save and match" go="/admin/tolls/{id}" testId="toll-log" fields={[
      { name: 'kind', label: 'Kind', type: 'select', required: true, value: 'ticket', options: [['toll_invoice', 'Toll'], ['ticket', 'Ticket'], ['camera_offence', 'Camera offence'], ['parking', 'Parking'], ['fine', 'Fine'], ['tow', 'Tow'], ['impound', 'Impound']] },
      { name: 'authority', label: 'Issued by', required: true }, { name: 'notice_number', label: 'Notice number' }, { name: 'plate', label: 'Plate' }, { name: 'transponder', label: 'or transponder' },
      { name: 'occurred_at', label: 'When it happened', type: 'datetime', required: true }, { name: 'time_unknown', label: 'Time not stated (date only)', type: 'bool' },
      { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'place', label: 'Place' }, { name: 'due_on', label: 'Due date', type: 'date' }, { name: 'received_on', label: 'Received', type: 'date' }, { name: 'note', label: 'Note', type: 'textarea' }]} /></Card>
  </>);
}
