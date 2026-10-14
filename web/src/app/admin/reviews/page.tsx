import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, BookingLink, Card, Filters, PageHead, Table, t, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Reviews', path: '/admin/reviews', noindex: true, description: 'Review moderation.' });
type R = Record<string, unknown>;

// Reviews (03-admin.md section 14): publish, hide only for cause (never because it is negative), reply;
// and the yes or no for asking a review after a booking with problems.
export default async function Reviews({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/reviews'), searchParams]);
  const status = sp.status ?? 'pending';
  const [{ rows }, held] = await Promise.all([list('reviews', { eq: status ? { status } : {}, limit: 200 }), list('review_request_decisions', { eq: { status: 'held' }, limit: 100 })]);
  const R = ['/admin/reviews'];
  return (<>
    <PageHead title="Reviews" />
    {held.rows.length > 0 && <Card title="Ask for a review after a booking with problems?" testId="review-decisions">
      <Table<R> rows={held.rows} rowKey={(r) => String(r.booking_id)} cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'problems', label: 'Problems', className: 'wrap', render: (r) => (r.problems as string[] | null)?.map(label).join(', ') },
        { key: 'act', label: 'Decide', render: (r) => <span className="ad-actions"><Act action="review_request_decide" payload={{ booking: r.booking_id, send: true }} label="Yes, ask" refresh={R} /><Act action="review_request_decide" payload={{ booking: r.booking_id, send: false }} label="No" fields={[{ name: 'note', label: 'Why not' }]} refresh={R} /></span> }]} /></Card>}
    <Filters base="/admin/reviews" name="status" value={status} sp={sp} options={[['pending', 'Pending'], ['published', 'Published'], ['hidden', 'Hidden']]} />
    <Table<R> testId="reviews" rows={rows} empty="No reviews here." cols={[{ key: 'created_at', label: 'Received', render: (r) => t(r.created_at) }, { key: 'rating', label: 'Rating', num: true }, { key: 'body', label: 'Review', className: 'wrap', render: (r) => <><b>{String(r.title ?? '')}</b> {String(r.body ?? '')}{r.staff_reply ? <span className="ad-sub muted small"> Reply: {String(r.staff_reply)}</span> : null}</> },
      { key: 'renter_name', label: 'Renter' }, { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'vehicle_name', label: 'Car' }, { key: 'publish_consent_at', label: 'May publish', render: (r) => (r.publish_consent_at ? 'Yes' : 'No, keep private') }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
      { key: 'act', label: 'Actions', render: (r) => <span className="ad-actions">
        {r.status !== 'published' && <Act action="review_publish" payload={{ id: r.id }} label="Publish" variant="primary" refresh={R} />}
        {r.status !== 'hidden' && <Act action="review_hide" payload={{ id: r.id }} label="Hide" fields={[{ name: 'reason', label: 'Reason', type: 'select', required: true, options: [['personal_information', 'Personal information'], ['abusive', 'Abusive'], ['not_about_the_rental', 'Not about the rental']] }]} refresh={R} />}
        <Act action="review_reply" payload={{ id: r.id }} label="Reply" fields={[{ name: 'reply', label: 'Public reply', type: 'textarea', value: r.staff_reply }]} refresh={R} /></span> }]} />
  </>);
}
