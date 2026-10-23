import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { when } from '@/features/agreement/model';
import { myDocuments, requireUser } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your documents', path: '/account/documents', noindex: true, description: 'Your rental agreements, receipts, statements and uploads.' });

const KIND: Record<string, string> = { rental_agreement: 'Rental agreement', receipt: 'Receipt', renter_statement: 'Statement', condition_report: 'Condition Report', coverage_proof: 'Proof of coverage', id_front: 'Licence, front', id_back: 'Licence, back', face: 'Selfie' };
const ID = ['id_front', 'id_back', 'face'];

export default async function Documents() {
  const user = await requireUser('/account/documents');
  const docs = await myDocuments(user);
  return (
    <>
      <PageHeader title="Your documents" purpose="Your rental agreements, receipts, statements and the photos you uploaded." />
      {!docs.length ? <div className="pt-empty"><p className="d4">No documents yet.</p><p className="muted">Agreements, receipts and statements appear here once you book.</p></div> : (
        <div className="table-scroll pt-card" tabIndex={0} role="region" aria-label="Documents">
          <table className="data ad-table--cards" role="table">
            <thead role="rowgroup"><tr role="row"><th scope="col">Document</th><th scope="col">Booking</th><th scope="col">Date</th><th scope="col"><span className="vh">Open</span></th></tr></thead>
            <tbody role="rowgroup">{docs.map((d) => (
              <tr key={d.id} role="row">
                <th scope="row" role="rowheader" data-label="Document">{KIND[d.kind] ?? d.title}{ID.includes(d.kind) && d.purge_after && <span className="xs muted"><br />Deleted after {when(d.purge_after, false)}</span>}</th>
                <td role="cell" data-label="Booking">{d.booking_number ?? ''}</td>
                <td role="cell" data-label="Date">{when(d.created_at, false)}</td>
                <td role="cell" data-label="Open">{d.purged ? <span className="muted small">Deleted</span> : <a className="link" href={`/account/documents/${d.id}`}>{ID.includes(d.kind) ? 'View' : 'Download'}</a>}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </>
  );
}
