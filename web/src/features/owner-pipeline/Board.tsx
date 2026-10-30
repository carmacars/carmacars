import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Table, t } from '@/features/admin/ui';
import { STAGES, SOURCES, byStage, followupWords, type PipelineLead } from './model';

export interface PipelineData {
  admin: boolean; followups_enabled: boolean; followup_days: number[]; kickback_bps: number; leads: PipelineLead[];
  credits: Array<Record<string, unknown>> | null; owner_links: Array<{ owner: string; code: string; url: string }> | null;
}

// The owner pipeline board (migration 0215), the same for an Admin and for staff working as Sales or Customer service:
// one column per stage, each lead with its follow-ups, Move, They replied and Stop or Restart. The database decides.
export function PipelineBoard({ d, refresh }: { d: PipelineData; refresh: string[] }) {
  const cols = byStage(d.leads);
  return (<>
    <Card title="Add a prospective owner" testId="op-add-card" aside={<Act action="owner_pipeline_add" label="Add an owner lead" variant="primary" refresh={refresh} done="Added." testId="op-add"
      fields={[{ name: 'name', label: 'Name', type: 'text', required: true }, { name: 'email', label: 'Email', type: 'email' }, { name: 'phone', label: 'Phone', type: 'tel' },
        { name: 'vehicle_text', label: 'The car (for example 2021 Honda Civic)', type: 'text' }, { name: 'source', label: 'How we heard of them', type: 'select', value: 'manual', options: [['manual', 'They asked us (phone, walk-in, message)'], ['referral', 'Someone referred them']] },
        { name: 'referral_code', label: 'Referring owner\'s code (if any)', type: 'text' }, { name: 'asked_us', label: 'They asked about the program (follow-up emails may go)', type: 'bool', value: true },
        { name: 'note', label: 'Note', type: 'textarea' }]} />}>
      <p className="small muted">{d.followups_enabled ? `Follow-up emails go by themselves on day ${d.followup_days.join(', ')} after a lead comes in, only with consent, and stop when they reply or the stage changes.` : 'Automatic follow-ups are off in Program settings.'} Classified-ad leads are added in Owner recruitment (Admin), with the consent log.</p>
    </Card>
    <div className="op-board" data-testid="op-board">
      {cols.map((c) => (
        <section key={c.stage} className="pt-card op-col" aria-labelledby={`op-h-${c.stage}`} data-testid={`op-col-${c.stage}`}>
          <h2 className="d4" id={`op-h-${c.stage}`}>{c.label} <span className="small muted">({c.leads.length})</span></h2>
          {c.leads.length ? <ul className="op-list">{c.leads.map((l) => (
            <li key={l.id} className="op-card" data-testid="op-lead">
              <b>{l.name ?? l.business_name ?? l.email ?? l.phone}</b>{l.vehicle && <span className="small">, {l.vehicle}</span>}
              <span className="xs muted">{SOURCES[l.source ?? ''] ?? l.source}{l.referred_by ? ` (by ${l.referred_by})` : ''}, {t(l.created_at)}{l.assignee ? `, with ${l.assignee}` : ''}</span>
              {(l.email || l.phone) && <span className="xs" style={{ overflowWrap: 'anywhere' }}>{[l.email, l.phone].filter(Boolean).join(', ')}</span>}
              <span className="xs muted">{l.replied_at ? `Replied ${t(l.replied_at)}. ` : ''}{followupWords(l, d.followup_days, t)}</span>
              {l.note && <span className="xs">{l.note}</span>}
              <span className="ad-actions">
                <Act action="owner_pipeline_save" payload={{ id: l.id }} label="Move" refresh={refresh} done="Saved." testId={`op-move-${l.id.slice(0, 8)}`}
                  fields={[{ name: 'stage', label: 'Stage', type: 'select', value: l.stage, options: STAGES }, { name: 'note', label: 'Note', type: 'textarea', value: l.note },
                    { name: 'reason', label: 'Why, when lost', type: 'text' }, { name: 'take', label: 'Make it mine', type: 'bool', value: false }]} />
                {!l.replied_at && <Act action="owner_pipeline_replied" payload={{ id: l.id }} label="They replied" variant="quiet" refresh={refresh} done="Follow-ups stopped." />}
                {l.followup_next_at ? <Act action="owner_pipeline_followups" payload={{ id: l.id, on: false }} label="Stop follow-ups" variant="quiet" refresh={refresh} done="Stopped." />
                  : l.stage === 'new' && l.followup_step < d.followup_days.length && <Act action="owner_pipeline_followups" payload={{ id: l.id, on: true }} label="Restart follow-ups" variant="quiet" refresh={refresh} done="Restarted." />}
              </span>
            </li>))}</ul> : <p className="small muted">None.</p>}
        </section>))}
    </div>
    {d.admin && d.credits && <Card title="Owner referral credits" testId="op-credits">
      <p className="small muted">An owner who refers a new owner earns the Kickback Rate ({d.kickback_bps / 100}%) of the Rental Charge of the first completed rental of the new owner&apos;s car, as for a renter referral. Paid by hand with the referrer&apos;s payout.</p>
      <Table<Record<string, unknown>> rows={d.credits} rowKey={(x) => String(x.id)} empty="No owner referrals yet." cols={[{ key: 'referrer', label: 'Referred by' }, { key: 'referred', label: 'New owner' },
        { key: 'status', label: 'Status', render: (x) => <Badge s={x.status === 'paid' ? 'published' : x.status === 'due' ? 'draft' : 'closed'}>{String(x.status === 'waiting' ? 'Waiting for the first rental' : x.status)}</Badge> },
        { key: 'booking', label: 'First rental' }, { key: 'amount_cents', label: 'Credit', num: true, render: (x) => $(x.amount_cents) },
        { key: 'act', label: '', render: (x) => (x.status === 'due' ? <Act action="owner_referral_credit_paid" payload={{ id: x.id }} label="Mark paid" refresh={refresh} done="Marked paid." fields={[{ name: 'note', label: 'Payout or reference', type: 'text' }]} /> : null) }]} />
    </Card>}
    {d.admin && d.owner_links && d.owner_links.length > 0 && <details className="pt-card"><summary className="small">Owners&apos; referral links for new owners ({d.owner_links.length})</summary>
      <ul className="small linklist">{d.owner_links.map((o) => <li key={o.code}>{o.owner}: <code style={{ overflowWrap: 'anywhere' }}>{o.url}</code></li>)}</ul></details>}
  </>);
}
