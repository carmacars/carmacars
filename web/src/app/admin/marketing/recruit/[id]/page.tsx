import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { BASIS, CALL_OUTCOMES, CALL_SCRIPT, CONTACT_KINDS, LEAD_STATUS, LISTING_SITES, TEMPLATES, fillTemplate, recruitLink, withStop, type ConsentState } from '@/features/ads/recruit';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Recruitment lead', path: '/admin/marketing/recruit', noindex: true, description: 'A prospective owner: consent log, calls and messages.' });
type R = Record<string, unknown>;
type Lead = { id: string; name: string | null; business_name: string | null; email: string | null; phone: string | null; listing_url: string | null; listing_site: string | null; contact_kind: string | null;
  vehicle_text: string | null; status: string; message: string | null; created_at: string; do_not_contact_at: string | null; email_state: ConsentState; text_state: ConsentState };
type Data = { lead: Lead; today: string; enabled: boolean; sender: string | null; company: { address: string | null; email: string | null; phone: string | null; site_url: string }; consents: R[]; calls: R[]; messages: R[] };
const word = (xs: Array<[string, string]>, k: unknown) => xs.find((x) => x[0] === k)?.[1] ?? String(k ?? '');

// Admin > Marketing > Owner recruitment > a lead (migration 0167): what may be sent and why, the call script and the call
// log, the consent log (never edited: a change is a new line), the templates (sent only when the log allows that channel)
// and every message sent.
export default async function RecruitLead({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/marketing/recruit/${id}`);
  const r = await read<Data | null>('recruit_lead', { id }).catch(() => null);
  if (!r) notFound();
  const l = r.lead;
  const refresh = [`/admin/marketing/recruit/${id}`, '/admin/marketing/recruit'];
  const vars = { first_name: (l.name ?? '').split(' ')[0] || undefined, vehicle: l.vehicle_text ?? undefined, sender: r.sender ?? undefined, phone: r.company.phone ?? undefined, business: l.business_name ?? undefined };
  const dnc = !!l.do_not_contact_at;
  const sendable = (ch: 'email' | 'text') => (ch === 'email' ? l.email_state : l.text_state);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/marketing/recruit">Owner recruitment</Link>} title={l.business_name ?? l.name ?? l.phone ?? 'Lead'}>
      <Act action="recruit_lead_save" payload={{ id }} label="Edit" testId="rc-edit" refresh={refresh} done="Saved."
        fields={[{ name: 'name', label: 'Name', type: 'text', value: l.name }, { name: 'business_name', label: 'Business name', type: 'text', value: l.business_name },
          { name: 'contact_kind', label: 'Who is selling', type: 'select', options: CONTACT_KINDS, value: l.contact_kind ?? 'private_seller', required: true },
          { name: 'phone', label: 'Phone', type: 'tel', value: l.phone }, { name: 'email', label: 'Email', type: 'email', value: l.email }, { name: 'vehicle_text', label: 'The car', type: 'text', value: l.vehicle_text },
          { name: 'listing_url', label: 'The ad\'s address', type: 'text', value: l.listing_url, wide: true },
          { name: 'status', label: 'Status', type: 'select', options: Object.entries(LEAD_STATUS) as Array<[string, string]>, value: l.status }, { name: 'note', label: 'Note', type: 'textarea', value: l.message }]} />
      {!dnc && <Act action="recruit_do_not_contact" payload={{ lead: id }} label="Do not contact" variant="danger" testId="rc-dnc" refresh={refresh} done="Recorded: never contact them again."
        fields={[{ name: 'reason', label: 'Why (their words)', type: 'text' }]} />}
    </PageHead>
    <MarketingTabs current="/admin/marketing/recruit" />
    <div className="ad-cols ad-cols--2">
      <Card title="Lead" testId="rc-summary">
        <Kv rows={[['Who', word(CONTACT_KINDS, l.contact_kind)], ['Car', l.vehicle_text], ['Ad', l.listing_url ? <a className="link" href={l.listing_url} target="_blank" rel="noopener noreferrer nofollow">{word(LISTING_SITES, l.listing_site) || l.listing_url}</a> : null],
          ['Phone', l.phone], ['Email', l.email], ['Status', dnc ? 'Do not contact' : LEAD_STATUS[l.status] ?? l.status], ['Added', d(l.created_at)], ['Note', l.message]]} />
      </Card>
      <Card title="What may be sent" testId="rc-state">
        <Kv rows={[['Email', l.email_state.allowed ? <span data-testid="rc-email-ok">Allowed: {word(BASIS.map((b) => [b[0], b[1]] as [string, string]), l.email_state.basis)}{l.email_state.expires_on ? ` until ${d(l.email_state.expires_on)}` : ''}</span> : <span data-testid="rc-email-no">No: {l.email_state.reason}</span>],
          ['Text', l.text_state.allowed ? <span data-testid="rc-text-ok">Allowed: {word(BASIS.map((b) => [b[0], b[1]] as [string, string]), l.text_state.basis)}{l.text_state.expires_on ? ` until ${d(l.text_state.expires_on)}` : ''}</span> : <span data-testid="rc-text-no">No: {l.text_state.reason}</span>],
          ['Phone call', dnc ? 'No: do not contact' : 'Allowed (a live call; the Do Not Call List rules apply)']]} />
        {!r.enabled && <p className="small">Recruitment emails and texts are off in Program settings.</p>}
      </Card>
    </div>
    {!dnc && <Card title="Call them" testId="rc-call">
      <ol className="small">{CALL_SCRIPT.map((s) => <li key={s}>{s}</li>)}</ol>
      <Act action="recruit_call_log" payload={{ lead: id }} label="Log the call" variant="primary" testId="rc-log-call" refresh={refresh} done="Call logged."
        fields={[{ name: 'outcome', label: 'How it went', type: 'select', options: CALL_OUTCOMES, required: true, value: 'yes_text' },
          { name: 'note', label: 'Their words (required for a yes: it is the proof of their consent)', type: 'textarea', placeholder: 'Yes, text me the details' }]} />
    </Card>}
    {!dnc && <Card title="Send a message" testId="rc-send">
      <p className="small muted">The email adds CarmaCars&apos; name, mailing address{r.company.address ? ` (${r.company.address})` : ''} and the unsubscribe link; the text ends with &quot;Reply STOP to opt out.&quot; An unsubscribe or a STOP is written into the log at once. Texts wait for 8 am in quiet hours.</p>
      <div className="stack">{TEMPLATES.map((tpl) => {
        const s = sendable(tpl.channel);
        const filled = fillTemplate(tpl, { ...vars, link: recruitLink(r.company.site_url, tpl.channel), referrer: (l.email_state.referrer_name ?? undefined) as string | undefined });
        return (
          <div key={tpl.key} className="row" style={{ gap: '0.75rem', flexWrap: 'wrap', alignItems: 'center' }}>
            <Act action="recruit_send" payload={{ lead: id, channel: tpl.channel, template: tpl.key }} label={`${tpl.channel === 'email' ? 'Email' : 'Text'}: ${tpl.label}`} testId={`rc-send-${tpl.key}`}
              disabled={!s.allowed || !r.enabled} refresh={refresh} done={tpl.channel === 'email' ? 'Email queued.' : 'Text queued.'} submitLabel="Send"
              fields={[...(tpl.channel === 'email' ? [{ name: 'subject', label: 'Subject', type: 'text' as const, value: filled.subject, required: true, wide: true }] : []),
                { name: 'body', label: tpl.channel === 'email' ? 'Message (the greeting, our address and the unsubscribe are added)' : 'Text (the STOP line is added)', type: 'textarea', value: filled.body, required: true }]} />
            <span className="small muted">{tpl.when}{!s.allowed ? `: not now (${s.reason})` : ''}</span>
            {tpl.channel === 'text' && s.allowed && <span className="small muted">Sends as: {withStop(filled.body).slice(0, 90)}...</span>}
          </div>);
      })}</div>
    </Card>}
    <Card title="Consent log" testId="rc-consents" aside={<Act action="recruit_consent_add" payload={{ lead: id }} label="Record consent" testId="rc-add-consent" refresh={refresh} done="Recorded."
      fields={[{ name: 'basis', label: 'Kind', type: 'select', options: BASIS.filter((b) => b[0] !== 'do_not_contact').map((b) => [b[0], b[1]] as [string, string]), required: true, value: 'express' },
        { name: 'channel', label: 'For', type: 'select', options: [['any', 'Email and text'], ['email', 'Email only'], ['text', 'Text only']], required: true, value: 'any' },
        { name: 'method', label: 'How', type: 'select', options: [['oral', 'On a call'], ['written', 'In writing'], ['form', 'A form on the site'], ['reply', 'They wrote to us'], ['published', 'Published address'], ['referral', 'A referral'], ['staff', 'Other']] },
        { name: 'source', label: 'Where and when, in words', type: 'text', required: true, wide: true }, { name: 'evidence', label: 'Proof: their words and the time, a recording, the message or the page address', type: 'textarea' },
        { name: 'referrer_name', label: 'Referred by (a referral)', type: 'text' }, { name: 'obtained_on', label: 'Date', type: 'date', value: r.today, required: true }]} />}>
      <details className="small"><summary>The kinds of consent</summary><ul>{BASIS.map((b) => <li key={b[0]}><b>{b[1]}</b>: {b[2]}</li>)}</ul></details>
      <Table<R> rows={r.consents} rowKey={(x) => String(x.id)} empty="Nothing recorded: no email or text may go yet." cols={[
        { key: 'created_at', label: 'Recorded', render: (x) => t(x.created_at) }, { key: 'basis_words', label: 'Kind', render: (x) => <Badge s={['withdrawn', 'do_not_contact'].includes(String(x.basis)) ? 'closed' : 'published'}>{String(x.basis_words)}</Badge> },
        { key: 'channel', label: 'For', render: (x) => (x.channel === 'any' ? 'Email and text' : x.channel === 'email' ? 'Email' : 'Text') }, { key: 'source', label: 'How', className: 'wrap' },
        { key: 'evidence', label: 'Proof', className: 'wrap' }, { key: 'obtained_on', label: 'Given', render: (x) => d(x.obtained_on) }, { key: 'expires_on', label: 'Ends', render: (x) => (x.expires_on ? d(x.expires_on) : '') },
        { key: 'recorded_by', label: 'By' }]} />
    </Card>
    <Card title="Calls" testId="rc-calls">
      <Table<R> rows={r.calls} rowKey={(x, i) => `${String(x.at)}-${i}`} empty="No call logged." cols={[{ key: 'at', label: 'When', render: (x) => t(x.at) }, { key: 'outcome', label: 'Outcome', render: (x) => word(CALL_OUTCOMES, x.outcome) },
        { key: 'note', label: 'Their words', className: 'wrap' }, { key: 'by', label: 'By' }]} />
    </Card>
    <Card title="Messages sent" testId="rc-messages">
      <Table<R> rows={r.messages} rowKey={(x) => String(x.id)} empty="No message sent." cols={[{ key: 'at', label: 'When', render: (x) => t(x.at) }, { key: 'channel', label: 'By', render: (x) => (x.channel === 'email' ? 'Email' : 'Text') },
        { key: 'subject', label: 'Subject' }, { key: 'body', label: 'Message', className: 'wrap' }, { key: 'basis', label: 'Consent', render: (x) => word(BASIS.map((b) => [b[0], b[1]] as [string, string]), x.basis) },
        { key: 'status', label: 'Status' }, { key: 'by', label: 'Sent by' }]} />
    </Card>
  </>);
}
