import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { monthOf } from '@/features/owner/Blocks';
import { $, Badge, Card, PageHead, Table, Tabs, Tiles, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Company statements', path: '/admin/reports', noindex: true, description: 'CarmaCars monthly statements per vehicle, per owner and in total.' });
type R = Record<string, unknown>;
type CS = { statement: R; total: R | null; owners: R[]; vehicles: R[] } | null;
type SectionRow = { label: string; cents?: number; count?: number; unit?: string; bps?: number; text?: string; account?: string; strong?: boolean };
type Section = { key: string; title: string; note?: string | null; rows: SectionRow[] };
const rowValue = (r: SectionRow) => r.text ?? (r.cents !== undefined ? $(r.cents) : r.bps !== undefined ? `${(r.bps / 100).toFixed(1)}%` : r.count !== undefined ? `${r.count}${r.unit ? ` ${r.unit}` : ''}` : '');
const COLS = ['rental_revenue_cents', 'revenue_share_cents', 'owner_revenue_cents', 'company_fees_cents', 'insurance_fees_cents', 'tracker_fees_cents', 'refunds_cents', 'expenses_cents', 'company_net_cents'];
// the current version of the statement (rendered on each request; the emailed PDFs are stored under their version)
const docKey = (st: R) => String(st.id);
const nice = (k: string) => k.replace(/_cents$/, '').replace(/_/g, ' ');

// CarmaCars' own monthly statements (11-statements-and-reports.md sections 3 and 4), with the reconciliation ties.
export default async function Reports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/reports'), searchParams]);
  const now = new Date();
  const month = /^\d{4}-\d{2}$/.test(sp.month ?? '') ? `${sp.month}-01` : new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1)).toISOString().slice(0, 10);
  const [cs, sections] = await Promise.all([read<CS>('company_statement', { month }), read<Section[] | null>('company_sections', { month })]);
  const level = sp.level ?? 'total';
  const m = month.slice(0, 7);
  const months = Array.from({ length: 6 }, (_, i) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1)).toISOString().slice(0, 7));
  const R = ['/admin/reports'];
  // tie_problems is one text of problems joined by "; " (0021), or a list
  const rawProblems = cs?.statement.tie_problems as string | string[] | null | undefined;
  const problems = Array.isArray(rawProblems) ? rawProblems : typeof rawProblems === 'string' && rawProblems.trim() ? rawProblems.split(/;\s+/) : [];
  return (<>
    <PageHead title="Company statements" kicker={monthOf(month)}>
      <Act action="company_build" payload={{ month }} label={cs ? 'Rebuild' : 'Build the statement'} variant="primary" testId="company-build" refresh={R} />
      {cs && cs.statement.status !== 'final' && <Act action="company_finalize" payload={{ month }} label="Finalize" confirm="Finalize the month: it is rebuilt, the ties must pass, and it is never rebuilt again." refresh={R} />}
      {cs && <><a className="btn btn--ghost btn--sm" href={`/admin/reports/export?kind=company&month=${month}&level=${level === 'total' ? 'total' : level}`}>CSV</a><a className="btn btn--ghost btn--sm" href={`/admin/reports/export?kind=ledger&month=${month}`}>Ledger CSV</a>
        <a className="btn btn--ghost btn--sm" data-testid="company-pdf" href={`/files/company_statement/${docKey(cs.statement)}`}>PDF</a>
        <a className="btn btn--ghost btn--sm" href={`/files/company_owners/${docKey(cs.statement)}`}>PDF by owner</a>
        <a className="btn btn--ghost btn--sm" href={`/files/company_vehicles/${docKey(cs.statement)}`}>PDF by vehicle</a>
        <Act action="company_statement_email" payload={{ month }} label="Email me the PDFs" done="Sent to your email." refresh={R} testId="company-email" /></>}
    </PageHead>
    <Tabs label="Month" current={`/admin/reports?month=${m}`} items={months.map((x) => [`/admin/reports?month=${x}`, monthOf(`${x}-01`)])} />
    {!cs ? <p className="ad-empty">No statement for this month yet. Build it.</p> : <>
      <div className={`ad-tie${cs.statement.ties_ok ? '' : ' is-bad'}`} data-testid="company-ties" role="status">
        <b>{cs.statement.ties_ok ? 'The ties pass' : 'The ties do not pass'}</b> · <Badge s={String(cs.statement.status)} /> · built {t(cs.statement.built_at)}
        {problems.length > 0 && <ul className="small">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
      </div>
      {cs.total && <Tiles items={COLS.map((k) => ({ k: nice(k), v: $(cs.total![k]) }))} />}
      <Tabs label="Level" current={`/admin/reports?month=${m}&level=${level}`} items={[[`/admin/reports?month=${m}&level=total`, 'Total'], [`/admin/reports?month=${m}&level=owner`, `Per owner (${cs.owners.length})`], [`/admin/reports?month=${m}&level=vehicle`, `Per vehicle (${cs.vehicles.length})`]]} />
      {level === 'total' && (sections ?? []).length > 0 && <div className="stack" data-testid="company-sections">{(sections ?? []).map((sec) => (
        <Card key={sec.key} title={sec.title}>
          {sec.rows.length ? <dl className="pt-dl pt-dl--money">{sec.rows.map((r, i) => <div key={`${sec.key}-${i}`}><dt>{r.strong ? <b>{r.label}</b> : r.label}{r.account ? <span className="muted small"> {r.account}</span> : null}</dt><dd>{r.strong ? <b>{rowValue(r)}</b> : rowValue(r)}</dd></div>)}</dl>
            : <p className="small muted">Nothing this month.</p>}
          {sec.note && <p className="small muted">{sec.note}</p>}
        </Card>))}</div>}
      {level === 'total' && cs.total && <Card title="Every column of the total"><dl className="pt-dl pt-dl--money">{Object.entries(cs.total).filter(([k, v]) => k.endsWith('_cents') && typeof v === 'number').map(([k, v]) => <div key={k}><dt>{nice(k)}</dt><dd>{$(v)}</dd></div>)}</dl></Card>}
      {level !== 'total' && <Table rows={level === 'owner' ? cs.owners : cs.vehicles} rowKey={(r, i) => String(r.id ?? i)} cols={[{ key: 'name', label: level === 'owner' ? 'Owner' : 'Vehicle', render: (r) => String(level === 'owner' ? r.owner_name : r.vehicle_name ?? '') },
        ...COLS.map((k) => ({ key: k, label: nice(k), num: true, render: (r: R) => $(r[k]) }))]} />}
      {!(sections ?? []).length && <Card title="Checks"><pre className="pt-mono" style={{ whiteSpace: 'pre-wrap' }}>{JSON.stringify(cs.statement.checks, null, 1)}</pre></Card>}
    </>}
  </>);
}
