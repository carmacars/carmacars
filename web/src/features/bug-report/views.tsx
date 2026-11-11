import './bug-report.css';
import Link from '@/components/Link';
import { Badge, Card, Kv, Table, t } from '@/features/admin/ui';
import type { LogEntry } from './logs';

// Release 37 (2340): the bug report pages (Admin > Bug reports and the staff's My bug reports).
export type BugRow = { id: string; number: string; status: string; severity: string; portal: string; page_path: string; happened: string; created_at: string;
  fixed_in: string | null; status_changed_at: string | null; screenshot_count: number; reporter: { id: string; name: string } | null };
export type BugFull = BugRow & { expected: string | null; steps: string | null; context: Record<string, unknown>; client_logs: LogEntry[];
  screenshots: Array<{ path: string; mime: string; bytes: number; kind: string }>; admin_notes: string | null;
  server_errors?: { client_errors_of_reporter: Array<Record<string, unknown>>; client_errors_on_page: Array<Record<string, unknown>>; failed_api_calls: Array<Record<string, unknown>> } };
export type BugList = { reports: BugRow[]; counts: Record<'new' | 'triaged' | 'fixed' | 'wont_fix', number> };

export const STATUS_LABEL: Record<string, string> = { new: 'New', triaged: 'Being looked at', fixed: 'Fixed', wont_fix: 'Won\'t fix' };
export const SEVERITY_LABEL: Record<string, string> = { blocks_work: 'Blocks work', annoying: 'Annoying', cosmetic: 'Cosmetic' };

export function BugTable({ rows, href, who }: { rows: BugRow[]; href: (r: BugRow) => string; who: boolean }) {
  return (
    <Table<BugRow & Record<string, unknown>> testId="bug-reports" rowKey={(r) => r.id} empty="No bug reports." rows={rows as Array<BugRow & Record<string, unknown>>} cols={[
      { key: 'number', label: 'Report', render: (r) => <Link prefetch={false} className="link" href={href(r)}>{r.number}</Link> },
      { key: 'created_at', label: 'Sent', render: (r) => t(r.created_at) },
      ...(who ? [{ key: 'reporter', label: 'From', render: (r: BugRow) => r.reporter?.name ?? '' }] : []),
      { key: 'severity', label: 'How bad', render: (r) => <Badge s={r.severity === 'blocks_work' ? 'overdue' : r.severity}>{SEVERITY_LABEL[r.severity] ?? r.severity}</Badge> },
      { key: 'happened', label: 'What happened', render: (r) => <span>{r.happened}{r.screenshot_count ? <span className="small muted"> · {r.screenshot_count} picture{r.screenshot_count > 1 ? 's' : ''}</span> : null}</span> },
      { key: 'page_path', label: 'Page', render: (r) => <code className="small">{r.page_path}</code> },
      { key: 'status', label: 'Status', render: (r) => <Badge s={r.status}>{STATUS_LABEL[r.status] ?? r.status}{r.fixed_in ? ` in ${r.fixed_in}` : ''}</Badge> }
    ]} />
  );
}

export function BugDetail({ r, admin }: { r: BugFull; admin: boolean }) {
  const ctx = r.context ?? {};
  return (<>
    <Card title="What happened">
      <Kv rows={[['Status', <Badge key="s" s={r.status}>{STATUS_LABEL[r.status] ?? r.status}{r.fixed_in ? ` in ${r.fixed_in}` : ''}</Badge>], ['How bad', SEVERITY_LABEL[r.severity] ?? r.severity],
        ['From', r.reporter?.name ?? ''], ['Sent', t(r.created_at)], ['Page', <code key="p">{r.page_path}</code>], ['Portal', r.portal]]} />
      <p className="br-pre" data-testid="bug-happened">{r.happened}</p>
      {r.expected ? <><h3>Expected</h3><p className="br-pre">{r.expected}</p></> : null}
      {r.steps ? <><h3>Steps</h3><p className="br-pre">{r.steps}</p></> : null}
      {r.admin_notes && admin ? <><h3>Notes</h3><p className="br-pre">{r.admin_notes}</p></> : null}
    </Card>
    {r.screenshots.length ? (
      <Card title={`Pictures (${r.screenshots.length})`}>
        <div className="br-shots">{r.screenshots.map((s, i) => (
          <a key={s.path} href={`/api/bug-report?id=${r.id}&n=${i}`} target="_blank" rel="noopener noreferrer">
            {/* private files, read through the site for the reporter or an Admin */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={`/api/bug-report?id=${r.id}&n=${i}`} alt={s.kind === 'auto' ? 'Picture of the page when the report was opened' : `Picture ${i + 1}`} loading="lazy" />
          </a>
        ))}</div>
      </Card>
    ) : null}
    <Card title="Browser and build">
      <Kv rows={Object.entries(ctx).filter(([k]) => !['roles', 'functions'].includes(k)).map(([k, v]) => [k.replace(/_/g, ' '), typeof v === 'object' ? JSON.stringify(v) : String(v ?? '')])
        .concat([['roles', JSON.stringify(ctx.roles ?? [])], ['functions', JSON.stringify(ctx.functions ?? [])]]) as Array<[string, string]>} />
    </Card>
    <Card title={`Errors in the browser (${r.client_logs.length}, newest last)`}>
      {r.client_logs.length ? (
        <table className="br-logs" data-testid="bug-logs"><thead><tr><th>When</th><th>Kind</th><th>What</th></tr></thead>
          <tbody>{r.client_logs.map((l, i) => (
            <tr key={i}><td>{t(l.at)}</td><td>{l.kind}{l.status !== undefined ? ` ${l.status}` : ''}</td><td>{l.method ? `${l.method} ` : ''}{l.url ? <code>{l.url}</code> : null} {l.msg}{l.ray ? <span className="small muted"> (ray {l.ray})</span> : null}</td></tr>
          ))}</tbody></table>
      ) : <p className="muted">No errors or failed calls before the report.</p>}
    </Card>
    {admin && r.server_errors ? (
      <Card title="On the server side">
        <h3>Crashes in this person&apos;s browser (2 hours before)</h3>
        <pre className="br-pre">{r.server_errors.client_errors_of_reporter.length ? JSON.stringify(r.server_errors.client_errors_of_reporter, null, 1) : 'None.'}</pre>
        <h3>Crashes on this page (30 minutes before)</h3>
        <pre className="br-pre">{r.server_errors.client_errors_on_page.length ? JSON.stringify(r.server_errors.client_errors_on_page, null, 1) : 'None.'}</pre>
        <h3>Failed connector calls</h3>
        <pre className="br-pre">{r.server_errors.failed_api_calls.length ? JSON.stringify(r.server_errors.failed_api_calls, null, 1) : 'None.'}</pre>
      </Card>
    ) : null}
  </>);
}
