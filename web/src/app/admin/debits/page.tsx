import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, Kv, PageHead, Table, Tiles, t } from '@/features/admin/ui';

const ord = (n: number) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner debits', path: '/admin/debits', noindex: true, description: 'The automatic monthly pre-authorized debit of owner invoices.' });

type R = Record<string, unknown>;
interface Debits {
  settings: { enabled: boolean; debit_day: number; retry_day: number; notice_days: number; max_attempts: number; retry_gap_days: number; run_hour: number; kinds: string[]; late_fee_cents: number };
  next_debit_on: string; next_notice_on: string;
  counts: { scheduled: number; processing: number; failed_30d: number; succeeded_30d: number; scheduled_cents: number; processing_cents: number };
  upcoming: R[]; recent: R[]; runs: R[]; notices: R[]; paused_owners: R[]; paused_invoices: R[]; owners: R[];
}
const STATUS: Record<string, string> = { scheduled: 'Scheduled', submitting: 'Sending', processing: 'Processing', succeeded: 'Cleared', failed: 'Returned', skipped: 'Not sent', canceled: 'Not needed' };
const R = ['/admin/debits'];
const inv = (r: R) => <Link prefetch={false} className="link" href={`/admin/owners/${String(r.owner_id)}#inv-${String(r.invoice_number)}`}>{String(r.invoice_number)}</Link>;

// The automatic monthly owner debit (migration 0037, docs/changes/2026-10-14-owner-debit.md): what is scheduled, what
// went to the bank and what came back, the run log, and the pauses. The schedule and the retry policy are Program settings.
export default async function OwnerDebits() {
  const { read } = await page('/admin/debits');
  const x = await read<Debits>('owner_debits');
  const s = x.settings;
  return (<>
    <PageHead title="Owner debits" kicker="Money">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/settings/program">Debit settings</Link>
    </PageHead>
    {!s.enabled && <Card title="Automatic debits are off" tone="warn"><p className="small">Nothing is scheduled or sent. Turn on owner_debit_enabled in Program settings.</p></Card>}
    <Tiles items={[
      { k: 'Next debit day', v: d(x.next_debit_on), sub: `Notices on ${d(x.next_notice_on)}` },
      { k: 'Scheduled', v: String(x.counts.scheduled), sub: $(x.counts.scheduled_cents) },
      { k: 'Processing at the bank', v: String(x.counts.processing), sub: $(x.counts.processing_cents) },
      { k: 'Cleared, 30 days', v: String(x.counts.succeeded_30d) },
      { k: 'Returned, 30 days', v: String(x.counts.failed_30d), warn: x.counts.failed_30d > 0 }
    ]} />
    <Card title="How it runs" testId="debit-policy">
      <Kv rows={[
        ['Debit day', `The ${ord(s.debit_day)} of each month (billing_day), from ${String(s.run_hour).padStart(2, '0')}:00 Toronto time`],
        ['Notice', `${s.notice_days} days before, by email, listing every invoice and the total`],
        ['Invoices debited', s.kinds.map((k) => k.replace(/_/g, ' ')).join(', ')],
        ['Returned for insufficient funds', `The ${$(s.late_fee_cents)} Late Fee once, as its own invoice line, collected with the next scheduled debit. ${s.max_attempts > 1 ? `One retry of the original amount only, on the later of day ${s.retry_day} and ${s.retry_gap_days} business days after the return, never more than 30 days after the debit. A failed retry puts the invoice in arrears` : 'No retry: the Late Fee and the amount are deducted from the next payout'}`],
        ['Returned for any other reason', 'No retry and no Late Fee. The invoice\'s automatic debit is paused, an Admin gets a task and an email, and the owner is asked to pay from the invoice page or update the bank account'],
        ['One debit per invoice', 'Each attempt is its own PaymentIntent with its own idempotency key, never more than the notice said']
      ]} />
    </Card>
    <Card title={`Scheduled and processing (${x.upcoming.length})`}>
      <Table testId="debit-upcoming" rows={x.upcoming} rowKey={(r) => String(r.id)} empty="Nothing scheduled. Notices go out on the notice day." cols={[
        { key: 'debit_on', label: 'Debit day', render: (r) => d(r.debit_on) },
        { key: 'owner_name', label: 'Owner', render: (r) => <Link prefetch={false} className="link" href={`/admin/owners/${String(r.owner_id)}`}>{String(r.owner_name)}</Link> },
        { key: 'invoice_number', label: 'Invoice', render: inv },
        { key: 'vehicle_name', label: 'Vehicle' },
        { key: 'attempt_no', label: 'Attempt', num: true },
        { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'bank_last4', label: 'Account', render: (r) => r.bank_last4 ? `ending ${String(r.bank_last4)}` : '' },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)}>{STATUS[String(r.status)] ?? String(r.status)}</Badge> },
        { key: 'pause', label: '', render: (r) => r.status === 'scheduled' ? <Act action="owner_debit_pause" payload={{ invoice: r.invoice_id }} label="Pause" title={`Pause the debit of ${String(r.invoice_number)}`}
            fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} /> : null }
      ]} />
    </Card>
    <Card title="Owners">
      <Table testId="debit-owners" rows={x.owners} rowKey={(r) => String(r.id)} empty="No owner has an invoice yet." cols={[
        { key: 'name', label: 'Owner', render: (r) => <><Link prefetch={false} className="link" href={`/admin/owners/${String(r.id)}`}>{String(r.name)}</Link>{r.is_test ? <> <Badge s="draft">test</Badge></> : null}</> },
        { key: 'mandate', label: 'Debit agreement', render: (r) => r.mandate ? `Active, ending ${String(r.bank_last4 ?? '')}` : <Badge s="failed">None</Badge> },
        { key: 'open_invoices', label: 'Open invoices', num: true },
        { key: 'open_cents', label: 'Open', num: true, render: (r) => $(r.open_cents) },
        { key: 'paused', label: 'Automatic debit', render: (r) => r.paused ? <Badge s="failed">Paused</Badge> : 'On' },
        { key: 'act', label: '', render: (r) => (<span className="row">
          {r.paused
            ? <Act action="owner_debit_resume" payload={{ owner: r.id }} label="Resume" refresh={R} />
            : <Act action="owner_debit_pause" payload={{ owner: r.id }} label="Pause" title={`Pause automatic debits for ${String(r.name)}`} fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={R} />}
          {s.enabled && !r.paused && Number(r.open_invoices) > 0 && <Act action="owner_debit_schedule" payload={{ owner: r.id }} label="Send a notice now" title={`Schedule ${String(r.name)}'s open invoices`}
            confirm={`Sends the pre-debit notice today for the open invoices not yet scheduled. The debit is ${s.notice_days} days from today unless you choose a later day.`}
            fields={[{ name: 'debit_on', label: 'Debit day (empty: the earliest the notice allows)', type: 'date' }]} refresh={R} />}
        </span>) }
      ]} />
    </Card>
    {x.paused_invoices.length > 0 && <Card title="Paused invoices">
      <Table rows={x.paused_invoices} rowKey={(r) => String(r.id)} cols={[
        { key: 'invoice_number', label: 'Invoice' }, { key: 'owner_name', label: 'Owner' }, { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) },
        { key: 'reason', label: 'Reason' }, { key: 'at', label: 'Since', render: (r) => t(r.at) },
        { key: 'act', label: '', render: (r) => <Act action="owner_debit_resume" payload={{ invoice: r.id }} label="Resume" refresh={R} /> }]} />
    </Card>}
    <Card title="Results">
      <Table testId="debit-recent" rows={x.recent} rowKey={(r) => String(r.id)} empty="No debit has settled yet." cols={[
        { key: 'at', label: 'When', render: (r) => t(r.at) },
        { key: 'owner_name', label: 'Owner' }, { key: 'invoice_number', label: 'Invoice', render: inv },
        { key: 'attempt_no', label: 'Attempt', num: true }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) },
        { key: 'status', label: 'Result', render: (r) => <Badge s={String(r.status)}>{STATUS[String(r.status)] ?? String(r.status)}</Badge> },
        { key: 'reason', label: 'Reason' }
      ]} />
    </Card>
    <Card title="Run log">
      <Table testId="debit-runs" rows={x.runs} rowKey={(r) => String(r.id)} empty="No run yet." cols={[
        { key: 'run_on', label: 'Day', render: (r) => d(r.run_on) }, { key: 'kind', label: 'Run', render: (r) => r.kind === 'notice' ? 'Notices' : 'Debits' },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
        { key: 'notices_sent', label: 'Notices', num: true }, { key: 'no_mandate', label: 'No agreement', num: true }, { key: 'scheduled', label: 'Scheduled', num: true },
        { key: 'submitted', label: 'Sent', num: true }, { key: 'submitted_cents', label: 'Sent amount', num: true, render: (r) => $(r.submitted_cents) },
        { key: 'succeeded', label: 'Cleared', num: true }, { key: 'failed', label: 'Returned', num: true }, { key: 'skipped', label: 'Not sent', num: true },
        { key: 'finished_at', label: 'Finished', render: (r) => t(r.finished_at) }
      ]} />
    </Card>
    <Card title="Notices sent">
      <Table rows={x.notices} rowKey={(r) => String(r.id)} empty="No notice yet." cols={[
        { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) }, { key: 'owner_name', label: 'Owner' }, { key: 'debit_on', label: 'Debit day', render: (r) => d(r.debit_on) },
        { key: 'invoices', label: 'Invoices', num: true }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
        { key: 'bank_last4', label: 'Account', render: (r) => r.mandate_missing ? <Badge s="failed">No agreement: asked to set up</Badge> : `ending ${String(r.bank_last4 ?? '')}` }
      ]} />
    </Card>
  </>);
}
