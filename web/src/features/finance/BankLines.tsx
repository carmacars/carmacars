import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { $, Badge, Table, d } from '@/features/admin/ui';
import { MATCH_LABEL, type BankLinesView } from './model';

const STATUS: Array<[BankLinesView['status'], string]> = [['unmatched', 'No match'], ['matched', 'Matched'], ['ignored', 'Set aside'], ['all', 'All']];

// Release 49 (3480): the bank lines. A line that fits exactly one record was matched by itself; the rest are matched here
// (the records that fit, nearest date first) or set aside with what they are. Each line still without a match after the
// set days is a To do for Finance; matching it closes the To do. Undo takes a reason. Every step is in the audit log.
export function BankLines({ v, page }: { v: BankLinesView; page: string }) {
  const RF = [page];
  return (
    <div className="stack" data-testid="bank-lines">
      <nav className="ad-tabs" aria-label="Bank lines">
        {STATUS.map(([k, l]) => (
          <Link prefetch={false} scroll={false} key={k} href={`${page}?tab=bank&status=${k}`} aria-current={v.status === k ? 'page' : undefined}>{l}{v.counts[k] ? <span className="pt__count">{v.counts[k]}</span> : null}</Link>
        ))}
      </nav>
      <Table testId="bank-lines-table" rows={v.rows} rowKey={(r) => r.id} sort={false}
        empty={v.status === 'unmatched' ? (v.counts.all ? 'Every bank line is matched or set aside.' : 'No bank lines yet: import the RBC download above.') : 'No lines here.'}
        cols={[
          { key: 'posted_on', label: 'Date', render: (r) => d(r.posted_on) },
          { key: 'description', label: 'Description', className: 'wrap', render: (r) => <>{r.description || 'No description'}{r.cheque_number ? <span className="small muted"> · cheque {r.cheque_number}</span> : null}<br /><span className="small muted">{r.account} · {r.last4}</span></> },
          { key: 'amount_cents', label: 'Amount', num: true, render: (r) => <b>{r.amount_cents > 0 ? '+' : ''}{$(r.amount_cents)}</b> },
          { key: 'status', label: 'Status', render: (r) => <><Badge s={r.status}>{r.status === 'unmatched' ? 'No match' : r.status === 'ignored' ? 'Set aside' : 'Matched'}</Badge>
            {r.status === 'matched' ? <span className="small muted"><br />{r.matched_label ?? MATCH_LABEL[r.match_kind ?? ''] ?? ''}{r.matched_auto ? ' (by itself)' : ''}</span> : null}
            {r.status === 'ignored' && r.note ? <span className="small muted"><br />{r.note}</span> : null}</> },
          { key: 'act', label: '', render: (r) => r.status === 'unmatched' ? (
            <span className="ad-actions">
              {r.candidates.length ? <Act action="bank_line_match" payload={{ line: r.id }} label={r.candidates.length === 1 ? 'Confirm the match' : `Match (${r.candidates.length} fit)`} variant="primary" testId={`bank-match-${r.id}`}
                fields={[{ name: 'pick', label: 'The record', type: 'select', required: true, value: `${r.candidates[0]!.table}:${r.candidates[0]!.id}`,
                  options: r.candidates.map((c) => [`${c.table}:${c.id}`, `${c.label}, ${$(c.amount_cents)}, ${d(c.on)}`] as [string, string]) },
                  { name: 'note', label: 'Note (optional)' }]} refresh={RF} done="Matched." /> : <span className="small muted">Nothing recorded fits</span>}
              <Act action="bank_line_match" payload={{ line: r.id, ignore: true }} label="Set aside" testId={`bank-ignore-${r.id}`}
                fields={[{ name: 'note', label: 'What it is (a bank fee, a transfer between CarmaCars accounts...)', required: true }]} refresh={RF} done="Set aside." />
            </span>
          ) : <Act action="bank_line_match" payload={{ line: r.id, unmatch: true }} label="Undo" variant="quiet" testId={`bank-undo-${r.id}`}
                fields={[{ name: 'note', label: 'Why', required: true }]} refresh={RF} done="Undone." /> }
        ]} />
      {v.imports.length ? (
        <details className="small">
          <summary>Last imports</summary>
          <ul>{v.imports.map((i) => <li key={i.id}>{d(i.created_at)} · {i.account} · {i.file_name ?? i.source.toUpperCase()}: {i.lines_new} new of {i.lines_in}, {i.lines_matched} matched{i.by ? ` · ${i.by}` : ''}</li>)}</ul>
        </details>
      ) : null}
    </div>
  );
}
