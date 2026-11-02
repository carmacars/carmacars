import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Table, t } from '@/features/admin/ui';
import { nextTorontoMorning } from '../model';

// Hiring > Emails to send (migration 0226): every decision of the calls (the rubric's Hire, No, No show and Good fit for
// Sales instead) with the email it sends. Nothing goes until an Admin presses Send all decision emails, now or at a time
// chosen; each candidate gets one email, never twice. A row not sent yet can be changed or undone (back to Maybe).
export type DecisionRow = { application_id: string; full_name: string; email: string | null; status: string; role: string; outcome: string; send_email: boolean;
  email_code: string | null; subject: string | null; personal_note: string | null; sales_role: string | null; decided_at: string; decided_by: string | null;
  send_after: string | null; sent_at: string | null };
export type DecisionsData = { rows: DecisionRow[]; waiting: number; emails: number; scheduled_at: string | null };

export const DECISION_WORDS: Record<string, string> = {
  hire: 'Hire', sales: 'Good fit for Sales instead', sales_shortlist: 'Sales shortlist (already applied for Sales)', decline: 'No', no_show: 'No show'
};
const EMAIL_WORDS: Record<string, string> = {
  applicant_hired: 'The next steps (welcome)', applicant_referred: 'The Sales offer, with the one-click apply link', applicant_declined: 'The polite decline',
  applicant_no_show: 'The polite no-show email'
};
export function emailLine(r: Pick<DecisionRow, 'email_code' | 'outcome' | 'sales_role'>): string {
  if (!r.email_code) return r.outcome === 'sales_shortlist' ? 'No email: they applied for Sales already (a note goes on that application)' : 'No email';
  return `${EMAIL_WORDS[r.email_code] ?? r.email_code}${r.outcome === 'sales' && r.sales_role ? ` (${r.sales_role})` : ''}`;
}

export function DecisionEmails({ d }: { d: DecisionsData }) {
  const R = ['/admin/hiring'];
  const mon = nextTorontoMorning(1, 9);
  const tue = nextTorontoMorning(null, 9);
  const waiting = d.rows.filter((r) => !r.sent_at);
  return (
    <Card title={`Emails to send (${d.waiting})`} testId="hiring-decisions" aside={d.scheduled_at ? <span className="small" data-testid="decisions-scheduled">Scheduled for {t(d.scheduled_at)}</span> : undefined}>
      <p className="small">A decision in the rubric sends nothing by itself. Check the list, change or undo what you need, then send them all: one email per candidate, never twice.</p>
      {waiting.length > 0 && <div className="row">
        <Act action="hiring_decisions_send" label={`Send all decision emails (${d.emails})`} variant="primary" testId="decisions-send" refresh={R}
          done="Done. Each candidate gets one email." submitLabel="Send"
          fields={[{ name: 'when', label: 'When', type: 'select', value: '', options: [['', 'Now'], [mon.iso, `${mon.label}, 9:00 am Toronto`], [tue.iso, `${tue.label}, 9:00 am Toronto`]] },
            { name: 'at', label: 'Or another time (optional)', type: 'datetime' }]} />
      </div>}
      <Table<DecisionRow & Record<string, unknown>> testId="decisions-table" rows={d.rows as Array<DecisionRow & Record<string, unknown>>} rowKey={(r) => r.application_id}
        empty="No decision yet. Choose Hire, No, No show or Good fit for Sales instead in a candidate's rubric."
        cols={[
          { key: 'full_name', label: 'Candidate', render: (r) => <Link prefetch={false} className="link" href={`/admin/hiring/${r.application_id}`}>{r.full_name}</Link> },
          { key: 'role', label: 'Role' },
          { key: 'outcome', label: 'Decision', render: (r) => <span data-testid={`decision-outcome-${r.application_id}`}>{DECISION_WORDS[r.outcome] ?? r.outcome}</span> },
          { key: 'email_code', label: 'Email that will go', className: 'wrap', render: (r) => <span data-testid={`decision-email-${r.application_id}`}>{r.send_email || r.outcome === 'sales_shortlist' ? emailLine(r) : 'No email (turned off)'}{r.subject && r.send_email ? <span className="small muted"> &quot;{r.subject}&quot;</span> : null}</span> },
          { key: 'state', label: 'State', render: (r) => (r.sent_at ? <Badge s="published">Sent {t(r.sent_at)}</Badge> : r.send_after ? <Badge s="draft">At {t(r.send_after)}</Badge> : <Badge s="draft">Waiting</Badge>) },
          { key: 'act', label: '', render: (r) => (r.sent_at ? null : <span className="ad-actions">
            <Act action="hiring_decide" payload={{ id: r.application_id }} label="Change" variant="quiet" refresh={[...R, `/admin/hiring/${r.application_id}`]} testId={`decision-change-${r.application_id}`} done="Saved."
              fields={[{ name: 'outcome', label: 'Decision', type: 'select', value: r.outcome === 'sales_shortlist' ? 'sales' : r.outcome, options: [['hire', 'Hire'], ['decline', 'No'], ['sales', 'Good fit for Sales instead'], ['no_show', 'No show']] },
                { name: 'send_email', label: 'Send the email', type: 'bool', value: r.send_email },
                { name: 'note', label: 'A personal line in the hire or no-show email (optional)', type: 'textarea', value: r.personal_note ?? '' }]} />
            <Act action="hiring_decision_undo" payload={{ id: r.application_id }} label="Undo" variant="quiet" refresh={[...R, `/admin/hiring/${r.application_id}`]} testId={`decision-undo-${r.application_id}`}
              done="Undone: the rubric says Maybe." confirm={`Undo the decision for ${r.full_name}? The rubric goes back to Maybe.`} /></span>) }]} />
    </Card>
  );
}
