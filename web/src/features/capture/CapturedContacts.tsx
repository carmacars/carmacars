import Link from 'next/link';
import { Badge, Card, Table, t } from '@/features/admin/ui';

// Contact capture (migration 0090), staff side: the name, email and phone typed into a form on the site, sent or not,
// with the account's state. Only what the person typed; no marketing without their consent.
export type CapturedRow = { id: string; form: string; name: string | null; email: string | null; phone: string | null; at: string; first_at: string; done: boolean;
  done_reason: string | null; state: string | null; renter_id: string | null; lead_id: string | null; task_id: string | null; email_confirmed: boolean | null;
  on_site: boolean; continue_sent: string | null };
export interface CapturedData { open: number; rows: CapturedRow[] }

export function CapturedContacts({ d, renterBase }: { d: CapturedData; renterBase?: string }) {
  return (
    <Card title={`Typed into forms (${d.open} not sent)`} testId="captured-contacts">
      <p className="small muted">Contact details typed into the booking request, contact, owner and game forms or the chat, saved as they were typed. Call or email to help them finish; no offers without their consent.</p>
      <Table rows={d.rows} rowKey={(r) => r.id} empty="Nothing typed in the last 30 days." cols={[
        { key: 'at', label: 'When', render: (r) => t(r.at) },
        { key: 'name', label: 'Name', render: (r) => <span>{r.name ?? 'No name'}{r.on_site && <> <span className="ad-b ad-b--dark">On the site now</span></>}</span> },
        { key: 'email', label: 'Email', render: (r) => (r.email ? <span><a className="link" href={`mailto:${r.email}`}>{r.email}</a>{r.email_confirmed === false && <> <span className="ad-b ad-b--amber">Email not confirmed</span></>}</span> : '') },
        { key: 'phone', label: 'Phone', render: (r) => (r.phone ? <a className="link" href={`tel:${r.phone}`}>{r.phone}</a> : '') },
        { key: 'form', label: 'Form' },
        { key: 'done', label: 'Status', render: (r) => <Badge s={r.done ? 'done' : 'open'}>{r.done ? (r.done_reason ?? 'Sent') : 'Not sent'}</Badge> },
        { key: 'renter_id', label: '', render: (r) => (r.renter_id && renterBase ? <Link prefetch={false} className="link small" href={`${renterBase}/${r.renter_id}`}>Renter</Link> : '') }]} />
    </Card>
  );
}
