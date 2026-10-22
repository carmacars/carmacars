import Link from 'next/link';
import { ReachCard } from '@/features/admin/ReachCard';
import type { Reach } from '@/features/phone/alerts';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { monthOf } from '@/features/owner/Blocks';
import { door } from '@/server/door';
import { PaperSignatureForm, PaperSignatureList, type PaperRow } from '@/features/manual/ManualRecords';
import { SendGenerated, SendToSign, SignRequestList, type SignRequestRow } from '@/features/manual/SignRequests';
import { $, Badge, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { InvestmentCountersign, type CountersignRow } from '@/features/admin/LegalActions';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor', path: '/admin/investors', noindex: true, description: 'One investor.' });
type R = Record<string, unknown>;
export default async function Investor({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user } = await page(`/admin/investors/${id}`);
  const i = await read<(R & { investments: R[]; returns: R[]; documents: R[]; payouts: R[] }) | null>('investor', { id });
  if (!i) notFound();
  const [requests, paper, countersign] = await Promise.all([door<SignRequestRow[]>(user.id, 'ops_read', 'sign_requests', { investor: id }).catch(() => [] as SignRequestRow[]),
    door<PaperRow[]>(user.id, 'ops_read', 'paper_signatures', { investor: id }).catch(() => [] as PaperRow[]),
    door<CountersignRow[]>(user.id, 'ops_read', 'investment_countersign_state', { investor_id: id }).catch(() => [] as CountersignRow[])]);
  const reach = await door<Reach>(user.id, 'admin_read', 'notify_reach', { investor_id: id }).catch(() => null);
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const here = [`/admin/investors/${id}`];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/investors">Investors</Link>} title={<>{String(i.legal_name)} <Badge s={String(i.status)} /></>} />
    <div className="ad-cols ad-cols--2">
      <Card title="Record"><Kv rows={[['Type', String(i.investor_type ?? '')], ['Email', String(i.email ?? '')], ['Phone', String(i.phone ?? '')], ['Address', String(i.address ?? '')], ['Tax resident in Canada', i.tax_resident_canada ? 'Yes' : 'No'], ['Identity verified', t(i.identification_verified_at)]]} /></Card>
      <ReachCard reach={reach} who={{ investor_id: id }} />
      <Card title="Investments"><Table rows={i.investments} empty="None." cols={[{ key: 'investment_date', label: 'Date', render: (r) => d(r.investment_date) }, { key: 'principal_cents', label: 'Principal', num: true, render: (r) => $(r.principal_cents) }, { key: 'yearly_bps', label: 'Yearly', num: true, render: (r) => `${Number(r.yearly_bps) / 100}%` }, { key: 'lockup_end_date', label: 'Lock-up ends', render: (r) => d(r.lockup_end_date) }, { key: 'status', label: 'Status' }]} /></Card>
      <Card title="Returns"><Table rows={i.returns} empty="None." cols={[{ key: 'return_month', label: 'Month', render: (r) => monthOf(String(r.return_month)) }, { key: 'return_cents', label: 'Return', num: true, render: (r) => $(r.return_cents) }, { key: 'disposition', label: 'Paid or reinvested' }, { key: 'status', label: 'Status' }, { key: 'pdf', label: 'Statement', render: (r) => <a className="link" href={`/files/investor_statement/${String(r.id)}`}>PDF</a> }]} />
        <p className="small">Yearly summaries: {[...new Set(i.returns.map((r) => String(r.return_month).slice(0, 4)))].map((y) => <a key={y} className="link" href={`/files/investor_year/${id}:${y}`} data-testid="investor-year">{y} </a>)}</p></Card>
      <Card title="Documents and payouts"><Table rows={i.documents} empty="No documents." cols={[{ key: 'title', label: 'Document' }, { key: 'kind', label: 'Kind' }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} />
        <Table rows={i.payouts} empty="No payouts." cols={[{ key: 'kind', label: 'Payout' }, { key: 'amount_cents', label: 'Amount', num: true, render: (r) => $(r.amount_cents) }, { key: 'status', label: 'Status' }, { key: 'paid_at', label: 'Paid', render: (r) => t(r.paid_at) }]} /></Card>
      <Card title="Investment agreement" testId="investor-signing">
        <div className="stack">
          <p className="small">Send the agreement to sign in the investor portal (filled in from this record, or a PDF of your own), or record one signed on paper. Either way it counts as signed by the investor. It is not countersigned automatically: the signing officer countersigns it here, and CarmaCars is bound once it has countersigned and the funds clear.</p>
          <InvestmentCountersign investorId={id} rows={countersign} />
          <SignRequestList rows={requests} refresh={here} />
          <PaperSignatureList rows={paper} canVoid refresh={here} />
          <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
            {!requests.some((r) => r.status === 'sent' || r.status === 'signed') && <SendGenerated docType="investment_agreement" who={id} refresh={here} />}
            <SendToSign docType="investment_agreement" who={id} defaultTitle="Investment agreement" refresh={here} />
            <PaperSignatureForm docs={[{ doc_type: 'investment_agreement', target_id: id, label: 'Investment agreement', signer: String(i.legal_name ?? '') }]} today={today} refresh={here} />
          </div>
        </div>
      </Card>
    </div>
  </>);
}
