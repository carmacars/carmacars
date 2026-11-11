import { Act } from '@/features/admin/Act';
import { Badge, Card, Table, t } from '@/features/admin/ui';
import { OutsideReviewForm } from './OutsideReviewForm';

// Customer reviews received outside the site (release 36, migration 2002): the form and the list. Admin can hide one
// for cause; staff (customer service, sales) add and see them.
export type OutsideRow = { id: string; reviewer_name: string; source_label: string; received_on: string; rating: number; body: string; status: string; hidden_reason: string | null;
  proof: boolean; vehicle: string | null; entered_by: string | null; created_at: string };
export function OutsideReviews({ rows, cars, admin, refresh }: { rows: OutsideRow[]; cars: Array<{ id: string; name: string }>; admin: boolean; refresh: string[] }) {
  return (
    <Card title="Customer reviews received elsewhere" testId="outside-reviews">
      <p className="small muted">Reviews from Turo, earlier platforms, texts, calls and email, shown on the site with their source (for example &quot;via Turo&quot;) and counted in the rating.</p>
      <OutsideReviewForm cars={cars} />
      <Table<OutsideRow> testId="outside-reviews-list" rows={rows} rowKey={(r) => r.id} empty="None entered yet."
        cols={[{ key: 'received_on', label: 'Received', render: (r) => t(r.received_on) }, { key: 'reviewer_name', label: 'Reviewer' }, { key: 'source_label', label: 'Source' },
          { key: 'rating', label: 'Rating', num: true }, { key: 'body', label: 'Review', className: 'wrap' }, { key: 'vehicle', label: 'Car', render: (r) => r.vehicle ?? 'Fleet' },
          { key: 'proof', label: 'Proof', render: (r) => (r.proof ? 'On file' : '') }, { key: 'entered_by', label: 'Entered by' }, { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
          ...(admin ? [{ key: 'act', label: 'Actions', render: (r: OutsideRow) => (r.status === 'published'
            ? <Act action="outside_review_hide" payload={{ id: r.id }} label="Hide" fields={[{ name: 'reason', label: 'Reason', type: 'select', required: true, options: [['personal_information', 'Personal information'], ['abusive', 'Abusive'], ['not_about_the_rental', 'Not about the rental'], ['entered_by_mistake', 'Entered by mistake']] }]} refresh={refresh} />
            : <Act action="outside_review_hide" payload={{ id: r.id, reason: '' }} label="Show again" refresh={refresh} />) }] : [])]} />
    </Card>
  );
}
