import { pageMeta } from '@/features/seo/meta';
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
      <h1 className="d2">Your documents</h1>
      {!docs.length ? <div className="pt-empty"><p className="d4">No documents yet.</p><p className="muted">Agreements, receipts and statements appear here once you book.</p></div> : (
        <div className="table-scroll pt-card" tabIndex={0} role="region" aria-label="Documents">
          <table className="data">
            <thead><tr><th scope="col">Document</th><th scope="col">Booking</th><th scope="col">Date</th><th scope="col"><span className="vh">Open</span></th></tr></thead>
            <tbody>{docs.map((d) => (
              <tr key={d.id}>
                <th scope="row">{KIND[d.kind] ?? d.title}{ID.includes(d.kind) && d.purge_after && <span className="xs muted"><br />Deleted after {when(d.purge_after, false)}</span>}</th>
                <td>{d.booking_number ?? ''}</td>
                <td>{when(d.created_at, false)}</td>
                <td>{d.purged ? <span className="muted small">Deleted</span> : <a className="link" href={`/account/documents/${d.id}`}>{ID.includes(d.kind) ? 'View' : 'Download'}</a>}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </>
  );
}
