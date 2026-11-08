import Link from '@/components/Link';
import './sales-leads.css';
import { Card, Kv, PageHead, t, $ } from '@/features/admin/ui';
import { LeadActions, NextLead } from './LeadActions';
import { CHANNEL_LABEL, HISTORY_LABEL, OUTCOME_LABEL, stateOf, TYPE_LABEL, type LeadDetail } from './model';

const FORM_LABEL: Record<string, string> = { topic: 'Topic', booking_number: 'Booking', vehicle: 'Car', car: 'Car', pickup: 'Pickup', return: 'Return', pickup_at: 'Pickup', return_at: 'Return',
  budget: 'Budget', timeline: 'When', ownership: 'Ownership', year: 'Year', make: 'Make', model: 'Model', km: 'Kilometres', note: 'Note' };

/** One lead (the page every new-lead alert opens): who, the source in plain words, the form text or the chat transcript, the
 *  calls, every contact logged, the claim history, and the buttons. `base` is the list on this portal. */
export function LeadPage({ d, base, chatHref }: { d: LeadDetail; base: string; chatHref: string | null }) {
  const form = Object.entries(d.form ?? {}).filter(([, v]) => v);
  return (
    <>
      <PageHead title={d.name ?? d.phone ?? d.email ?? 'Lead'} kicker={<>{TYPE_LABEL[d.type]} lead · {d.source}</>} purpose={`${stateOf(d)}. Received ${t(d.created_at)}.`}>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={base}>All leads</Link>
        <NextLead base={base} />
      </PageHead>
      <div className="stack" data-testid="lead-page" data-lead={d.id}>
        <Card title="Contact">
          <Kv rows={[['Name', d.name ?? ''], ['Phone', d.phone ?? <span className="muted">none</span>], ['Email', d.email ?? <span className="muted">none</span>], ['Source', <b key="s" data-testid="lead-source">{d.source}</b>],
            ...(d.vehicle ? [['Car', d.vehicle] as [string, string]] : []), ...(d.value_cents ? [['Value', $(d.value_cents)] as [string, string]] : []),
            ...(d.assigned_name ? [['Assigned to', d.assigned_name] as [string, string]] : []),
            ...(d.outcome ? [['Outcome', `${OUTCOME_LABEL[d.outcome]}${d.outcome_reason ? `: ${d.outcome_reason}` : ''}${d.outcome_by ? ` (${d.outcome_by})` : ''}${d.won_booking ? `, booking ${d.won_booking}` : ''}`] as [string, string]] : [])]} />
          <LeadActions lead={d} admin={d.admin} people={d.people} />
        </Card>
        {(d.message || form.length > 0) && <Card title="What they wrote" testId="lead-form">
          {d.message && <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{d.message}</p>}
          {form.length > 0 && <Kv rows={form.map(([k, v]) => [FORM_LABEL[k] ?? k, v])} />}
          {d.source_url && <p className="small muted" style={{ overflowWrap: 'anywhere' }}>From {d.source_url}</p>}
        </Card>}
        {d.transcript.length > 0 && <Card title="Live chat" testId="lead-transcript" aside={chatHref ? <Link prefetch={false} className="link small" href={chatHref}>Open the chat</Link> : undefined}>
          <ol className="sl-transcript">{d.transcript.map((m, i) => <li key={i} className="small"><b>{m.from === 'visitor' ? 'Visitor' : m.from === 'ai' ? 'Assistant' : 'Staff'}</b> <span className="muted">{t(m.at)}</span><br />{m.text}</li>)}</ol>
        </Card>}
        {d.calls.length > 0 && <Card title="Calls and texts">
          <ul className="stack small" style={{ listStyle: 'none', padding: 0, margin: 0 }}>{d.calls.map((c, i) => <li key={i}>{t(c.at)}: {c.missed ? 'Missed call' : `${c.kind === 'call' ? 'Call' : 'Text'} ${c.direction === 'in' ? 'from them' : 'to them'}`}{c.text ? `. ${c.text}` : ''}</li>)}</ul>
        </Card>}
        <Card title="Contacts logged" testId="lead-contacts">
          {d.contacts.length ? <ul className="stack small" style={{ listStyle: 'none', padding: 0, margin: 0 }}>{d.contacts.map((c, i) => <li key={i}>{t(c.at)}: <b>{CHANNEL_LABEL[c.channel] ?? c.channel}</b> by {c.by}{c.note ? `. ${c.note}` : ''}</li>)}</ul>
            : <p className="small muted">Nothing logged yet. Call, Text and Email log themselves.</p>}
        </Card>
        <Card title="Claim history" testId="lead-history">
          {d.history.length ? <ul className="stack small" style={{ listStyle: 'none', padding: 0, margin: 0 }}>{d.history.map((h, i) => <li key={i}>{t(h.at)}: {HISTORY_LABEL[h.action] ?? h.action} {h.who}{h.by ? ` by ${h.by}` : ''}{h.note ? ` (${h.note})` : ''}</li>)}</ul>
            : <p className="small muted">Nobody has claimed it yet.</p>}
        </Card>
      </div>
    </>
  );
}
