import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, d, PageHead, Table, Tiles } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Call flags', path: '/admin/call-flags', noindex: true, description: 'Salespeople\'s calls and texts flagged for a phone number, swearing or other risky words, with the line.' });

type R = Record<string, unknown>;
type Data = { open: number; rows: Array<{ id: string; source: string; category: string; phrase: string | null; line: string; speaker: string; blocked: boolean; staff: string | null; at: string; thread_id: string | null;
  reviewed_at: string | null; review_note: string | null; reviewed_by: string | null }>; words: Array<{ id: string; phrase: string; category: string; active: boolean }> };
const CATEGORY: Record<string, string> = { phone_number: 'Phone number', swearing: 'Swearing', off_platform_payment: 'Payment outside the site', personal_number: 'Personal number',
  cash_only: 'Cash only', threat: 'Threat', discrimination: 'Discrimination' };
const CATS = Object.entries(CATEGORY).filter(([k]) => k !== 'phone_number') as Array<[string, string]>;

// Admin > Team > Call flags (5137): each line a salesperson said on a call (a phone number, swearing, a payment outside the
// site, a personal number, cash only, a threat, discrimination) and each text with a phone number they tried to send
// (blocked). Mark reviewed with a note. The words list is below.
export default async function CallFlags({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/call-flags'), searchParams]);
  const x = await read<Data>('call_flags', { all: sp.all === '1' });
  const refresh = ['/admin/call-flags'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/sales-leads?tab=team">Sales team</Link>} title="Call flags"
      purpose="Salespeople's calls with a phone number or risky words, with the line from the transcript, and the texts with a phone number they tried to send (not sent)." />
    <Tiles items={[{ k: 'To review', v: x.open, warn: x.open > 0 }, { k: 'Texts blocked', v: x.rows.filter((r) => r.blocked).length }]} />
    <Card title="Flags" testId="call-flags" aside={<Link prefetch={false} className="link small" href={sp.all === '1' ? '/admin/call-flags' : '/admin/call-flags?all=1'}>{sp.all === '1' ? 'Recent only' : 'Show all'}</Link>}>
      <Table<R> rows={x.rows as unknown as R[]} rowKey={(r) => String(r.id)} empty="Nothing flagged. A salesperson's call with a phone number or risky words shows here with the line." cols={[
        { key: 'at', label: 'When', render: (r) => d(r.at) }, { key: 'staff', label: 'Salesperson' },
        { key: 'category', label: 'Why', className: 'wrap', render: (r) => <><Badge s={r.reviewed_at ? 'closed' : 'pending'}>{CATEGORY[String(r.category)] ?? String(r.category)}</Badge>{r.source === 'text' ? <span className="small muted"> text, not sent</span> : null}</> },
        { key: 'line', label: 'The line', className: 'wrap', render: (r) => <><q>{String(r.line)}</q>{r.speaker === 'unknown' ? <><br /><span className="small muted">The transcript does not say who spoke.</span></> : null}</> },
        { key: 'act', label: '', className: 'wrap', render: (r) => (r.reviewed_at ? <span className="small muted">Reviewed {d(r.reviewed_at)}{r.reviewed_by ? ` by ${String(r.reviewed_by)}` : ''}{r.review_note ? `: ${String(r.review_note)}` : ''}</span>
          : <Act action="call_flag_review" payload={{ flag: r.id }} label="Mark reviewed" refresh={refresh} done="Reviewed." testId={`cf-review-${String(r.id).slice(0, 8)}`}
              fields={[{ name: 'note', label: 'Note (what was done)', type: 'text' }]} />) }]} />
    </Card>
    <Card title="Words that flag a call" testId="call-flag-words" aside={<Act action="call_flag_word" label="Add a word" variant="primary" refresh={refresh} done="Added." testId="cf-word-add"
      fields={[{ name: 'phrase', label: 'Word or phrase', type: 'text', required: true }, { name: 'category', label: 'Category', type: 'select', required: true, options: CATS }]} />}>
      <Table<R> rows={x.words as unknown as R[]} rowKey={(r) => String(r.id)} empty="No words yet." cols={[
        { key: 'phrase', label: 'Word or phrase' }, { key: 'category', label: 'Category', render: (r) => CATEGORY[String(r.category)] ?? String(r.category) },
        { key: 'active', label: '', render: (r) => <Act action="call_flag_word" payload={{ id: r.id, active: !r.active }} label={r.active ? 'Switch off' : 'Switch on'} variant="quiet" refresh={refresh} done="Saved." /> }]} />
    </Card>
  </>);
}
