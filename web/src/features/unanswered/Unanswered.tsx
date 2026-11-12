import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card, Table } from '@/features/admin/ui';
import { door } from '@/server/door';
import { sortUnanswered, waitWords } from './model';

// Unanswered (1061): every customer text with no reply and every missed call not called back (Quo), oldest first; late
// ones (past the time of Program settings) marked. Open goes to the conversation; Mark answered when it was answered
// another way. WhatsApp is checked by hand (a morning digest line).
export interface UnansweredRow { thread_id: string; waiting_since: string; kind: 'text' | 'missed_call'; preview: string | null; minutes: number; late: boolean; name: string; number: string; booking_number: string | null; [k: string]: unknown }

export async function Unanswered({ userId, aal, base }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: '/admin' | '/staff' }) {
  const v = await door<{ sla_minutes: number; rows: UnansweredRow[] }>(userId, 'ops_read', 'unanswered', {}, aal);
  const late = v.rows.filter((r) => r.late).length;
  return (<>
    <p className="small muted">A customer waiting more than {v.sla_minutes} minutes alerts customer service and the Admins. WhatsApp is not in this list: check it each morning.</p>
    <Card title={`${v.rows.length} waiting${late ? `, ${late} late` : ''}`} testId="unanswered" tone={late ? 'warn' : undefined}>
      <Table<UnansweredRow> rows={sortUnanswered(v.rows)} rowKey={(r) => r.thread_id} empty="Every conversation is answered." cols={[
        { key: 'name', label: 'Who', render: (r) => <>{r.name}{r.booking_number ? <span className="muted small"> · {r.booking_number}</span> : null}</> },
        { key: 'kind', label: 'What', render: (r) => (r.kind === 'missed_call' ? 'Missed call' : 'Text') },
        { key: 'preview', label: 'Said', render: (r) => <span className="small">{r.preview ?? ''}</span> },
        { key: 'minutes', label: 'Waiting', render: (r) => <span className={r.late ? 'ad-late' : undefined}>{waitWords(r.minutes)}</span> },
        { key: 'thread_id', label: '', render: (r) => <span className="ad-actions">
          {/* calls first, texts after (r37): Call comes first, the text reply is the secondary button */}
          {r.number && <a className="btn btn--sm btn--primary" href={`tel:${r.number}`} data-testid={`unanswered-call-${r.thread_id}`}>{r.kind === 'missed_call' ? 'Call back' : 'Call'}</a>}
          <Link prefetch={false} className={`btn btn--sm ${r.number ? 'btn--quiet' : 'btn--primary'}`} href={`${base}/visitors?view=chat&inbox=phone&id=${r.thread_id}`}>{r.kind === 'missed_call' ? 'Open' : 'Reply'}</Link>
          <Act ops action="unanswered_done" payload={{ thread_id: r.thread_id }} label="Mark answered" refresh={[`${base}/unanswered`]} done="Marked answered." testId={`unanswered-done-${r.thread_id}`} /></span> }]} />
    </Card>
  </>);
}
