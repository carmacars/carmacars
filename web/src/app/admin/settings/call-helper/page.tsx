import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import type { Field } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Call helper', path: '/admin/settings/call-helper', noindex: true, description: 'What staff say on a call: the greetings, the situations with their steps, and the quick answers.' });

type Item = { id: string; kind: 'greeting' | 'situation' | 'faq'; code: string; title: string; body: string; keywords: string; sort_order: number; is_active: boolean; updated_at: string; updated_by: string | null; preview: string };
type Data = { items: Item[]; facts: Array<{ token: string; value: string; from: string }> };

// Admin > Settings > Call helper (migration 2670): the words of the Call helper inside the caller pop-up. Greetings (one
// per kind of caller, read out loud), situations (one button each; every line of the text is a step) and the quick
// answers staff search during a call. Changes show on the next call, with no release. The numbers are never typed: a
// word in braces is filled in from the settings, listed at the bottom with its value today.
export default async function CallHelperSettings() {
  const { read } = await page('/admin/settings/call-helper');
  const a = await read<Data>('call_helper_admin');
  const refresh = ['/admin/settings/call-helper'];
  const of = (k: Item['kind']) => a.items.filter((i) => i.kind === k);
  const words = 'Words in braces are filled in: {staff}, {caller}, {booking}, {car}, and the settings listed at the bottom of this page.';
  const link = 'A link to a page of the portal is written [Bookings](/bookings); the reader gets their own portal\'s page.';
  const fields = (kind: Item['kind'], r?: Item): Field[] => [
    ...(kind === 'greeting' ? [] : [{ name: 'title', label: kind === 'faq' ? 'Question' : 'Name on the button', required: true, value: r?.title ?? '', wide: true } as Field]),
    { name: 'body', label: kind === 'greeting' ? 'What to say' : kind === 'faq' ? 'Answer' : 'Steps, one a line (3 to 6 is best, 8 at most)', type: 'textarea', required: true, value: r?.body ?? '',
      hint: kind === 'greeting' ? words : `${words} ${link} Words in "quotes" are shown as what to say.`, info: false },
    ...(kind === 'faq' ? [{ name: 'keywords', label: 'More search words', value: r?.keywords ?? '', wide: true, hint: 'Other words a staff member might type, with spaces between.', info: false } as Field] : []),
    ...(kind === 'greeting' ? [] : [{ name: 'sort_order', label: 'Order', type: 'number', min: 0, max: 9999, value: r?.sort_order ?? '', info: false } as Field]),
    ...(r && r.code !== 'greeting_unknown' ? [{ name: 'is_active', label: 'On', type: 'bool', value: r.is_active, info: false } as Field] : [])
  ];
  const on = (x: Item) => (x.is_active ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>);
  const change = (x: Item) => (
    <Act action="call_helper_save" payload={{ id: x.id }} label="Change" title={x.title} submitLabel="Save" refresh={refresh} done="Saved. It shows on the next call." testId={`ch-change-${x.code}`} fields={fields(x.kind, x)} />);
  const remove = (x: Item) => (
    <Act action="call_helper_remove" payload={{ id: x.id }} label="Remove" variant="quiet" confirm={`Remove "${x.title}"? To hide it for a while, switch it off instead.`} refresh={refresh} done="Removed." testId={`ch-remove-${x.code}`} />);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Call helper"
      purpose="What staff see inside the caller pop-up while on a call: the greeting to read out, a button for each situation with its steps, and quick answers to search. A change shows on the next call." />
    <Card title="Greetings" testId="ch-greetings">
      <Table<Item> rows={of('greeting')} rowKey={(x) => x.code} cols={[{ key: 'title', label: 'Caller' }, { key: 'body', label: 'What to say', className: 'wrap' },
        { key: 'is_active', label: 'On', render: on }, { key: 'act', label: '', render: change }]} />
      <p className="small muted">The pop-up picks the greeting from who is calling. One that is off, or that needs a name we do not have, falls back to the greeting for a caller we do not know.</p>
    </Card>
    <Card title="Situations" testId="ch-situations" aside={<Act action="call_helper_save" payload={{ kind: 'situation' }} label="Add a situation" variant="primary" title="New situation" submitLabel="Add" refresh={refresh} done="Added." testId="ch-add-situation" fields={fields('situation')} />}>
      <Table<Item> rows={of('situation')} rowKey={(x) => x.code} empty="No situation yet." cols={[{ key: 'title', label: 'Button' },
        { key: 'body', label: 'Steps', className: 'wrap', render: (x) => <ol className="small">{x.preview.split('\n').filter((l) => l.trim()).map((l, i) => <li key={i}>{l}</li>)}</ol> },
        { key: 'sort_order', label: 'Order', num: true }, { key: 'is_active', label: 'On', render: on }, { key: 'act', label: '', render: (x) => <>{change(x)} {remove(x)}</> }]} />
      <p className="small muted">The steps are shown here as staff read them, with today&apos;s numbers from the settings.</p>
    </Card>
    <Card title="Quick answers" testId="ch-faq" aside={<Act action="call_helper_save" payload={{ kind: 'faq' }} label="Add a question" variant="primary" title="New question" submitLabel="Add" refresh={refresh} done="Added." testId="ch-add-faq" fields={fields('faq')} />}>
      <Table<Item> rows={of('faq')} rowKey={(x) => x.code} empty="No question yet." cols={[{ key: 'title', label: 'Question' }, { key: 'preview', label: 'Answer', className: 'wrap' },
        { key: 'is_active', label: 'On', render: on }, { key: 'act', label: '', render: (x) => <>{change(x)} {remove(x)}</> }]} />
    </Card>
    <Card title="Numbers from the settings" testId="ch-facts">
      <Table<{ token: string; value: string; from: string }> rows={a.facts} rowKey={(x) => x.token} cols={[{ key: 'token', label: 'Write', render: (x) => <code>{`{${x.token}}`}</code> },
        { key: 'value', label: 'Staff read today' }, { key: 'from', label: 'It comes from' }]} />
      <p className="small muted">Change a number where it lives (<Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link>, <Link prefetch={false} className="link" href="/admin/settings/fees">Fee defaults</Link>, <Link prefetch={false} className="link" href="/admin/settings/deposits">Deposit tiers</Link>) and every script follows. A word in braces that is not in this list is refused when you save.</p>
    </Card>
  </>);
}
