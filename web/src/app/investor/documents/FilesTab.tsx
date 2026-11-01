import { door } from '@/server/door';
import { when } from '@/features/agreement/model';
import { DocumentList, DocumentRow } from '@/components/portal-ui';

const KIND: Record<string, string> = { investment_agreement: 'Investment Agreement', investment_schedule_a: 'Schedule A', investment_schedule_c: 'Schedule C, risk acknowledgment', investment_schedule_d: 'Schedule D', investor_statement: 'Statement', securities_form: 'Securities form', notice: 'Notice' };

// Documents > Your files: your signed agreement, schedules and notices, each one a download (before r27 the Profile
// listed their names with no link).
export async function FilesTab({ userId }: { userId: string }) {
  const docs = await door<Array<{ id: string; kind: string; title: string | null; created_at: string }>>(userId, 'investor_read', 'documents').catch(() => []);
  if (!docs.length) return <div className="pt-empty" data-testid="investor-files-empty"><p className="d4">No files yet</p><p className="muted">Your signed Investment Agreement and its schedules appear here once they are signed.</p></div>;
  return (
    <DocumentList testId="investor-files" label="Your files">
      {docs.map((d) => <DocumentRow key={d.id} external href={`/investor/documents/${d.id}`} badge="PDF" title={d.title ?? KIND[d.kind] ?? d.kind.replace(/_/g, ' ')} meta={<><span>{KIND[d.kind] ?? d.kind.replace(/_/g, ' ')}</span><span>{when(d.created_at, false)}</span></>} />)}
    </DocumentList>
  );
}
