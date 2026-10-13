import 'server-only';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// The generated documents of a booking for staff (receipts, renter statements, the insurer invoice):
// each opens the PDF, rendered on request and kept once the record is final (migration 0032).
export async function GeneratedFiles({ bookingId }: { bookingId: string }) {
  const user = await currentUser();
  const files = user ? await door<Array<{ kind: string; key: string; title: string; at: string }>>(user.id, 'ops_read', 'files', { for: 'booking', id: bookingId }).catch(() => []) : [];
  if (!files.length) return <p className="small muted">No receipts or statements yet.</p>;
  return (
    <ul className="pt-list" data-testid="booking-files">{files.map((f) => (
      <li key={`${f.kind}:${f.key}`} className="pt-card__head"><span>{f.title}</span><a className="link" href={`/files/${f.kind}/${f.key}`}>PDF</a></li>
    ))}</ul>
  );
}
