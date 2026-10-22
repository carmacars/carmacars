import type { ReactNode } from 'react';
import { Act } from './Act';
import { Card, Kv, Table } from './ui';
import { renderSms, SMS_SAMPLE } from '@/features/phone/alerts';

// Admin > Settings > Text alerts (migration 0096): the defaults and quiet hours (Program settings), how many people
// chose each channel, and the short text of each notification with a preview.
export interface SmsTemplateRow { code: string; label: string; body: string; enabled: boolean; urgent: boolean; always_email: boolean; audience: string; subject: string }
export interface SmsSettings { templates: SmsTemplateRow[]; generic: number; always_email: string[]; people: { text: number; both: number; email: number; verified_phones: number }; opted_out: number; us_allowed: boolean }

const AUD: Record<string, string> = { renter: 'Renter', owner: 'Owner', investor: 'Investor' };

export function TextAlertsSettings({ data, form }: { data: SmsSettings; form: ReactNode }) {
  return (<>
    <p className="small muted">Each person chooses how we reach them: Email, Text or Both, on their profile, in the booking request and when they sign up with a phone number. Texts go only to a phone they verified with a code, from the CarmaCars number, and each has a link to the page. Signed documents, statements, receipts and invoices are always emailed when there is an email address; someone on Text also gets a text with a link to view or download it. A reply STOP stops texts at once (START turns them back on); we text one confirmation right away and email them instead. US numbers wait for A2P 10DLC registration{data.us_allowed ? ' (allowed now)' : ' (not allowed yet)'}. All of this is on now; nothing needs setting up.</p>
    <Card title="Defaults and quiet hours" testId="sms-defaults">{form}</Card>
    <Card title="People" testId="sms-people"><Kv rows={[['Chose Text', String(data.people.text)], ['Chose Both', String(data.people.both)], ['Chose Email', String(data.people.email)],
      ['Verified phones', String(data.people.verified_phones)], ['Numbers that replied STOP', String(data.opted_out)]]} />
      <p className="small muted">Everyone else has the default. Change one person&apos;s channel on their page (People &gt; Renters, Owners or Investors).</p></Card>
    <Card title={data.generic ? `Texts (${data.templates.length}, and ${data.generic} more from the email's subject)` : `Texts (${data.templates.length}, one for every customer email)`} testId="sms-templates">
      <p className="small muted">Placeholders are the email&apos;s, in double braces, and {'{{link}}'} is the page. 160 characters is one text. Urgent texts go during the quiet hours too.</p>
      <Table rows={data.templates as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.code)} cols={[
        { key: 'label', label: 'Notification', render: (r) => <span>{String(r.label)}<span className="ad-sub">{AUD[String(r.audience)] ?? String(r.audience)}{r.always_email ? ', always emailed too' : ''}{r.urgent ? ', urgent' : ''}{r.enabled ? '' : ', off'}</span></span> },
        { key: 'body', label: 'Text (preview)', render: (r) => { const p = renderSms(String(r.body), SMS_SAMPLE); return <span className="small">{p} <span className="muted">({p.length})</span></span>; } },
        { key: 'act', label: '', render: (r) => <Act action="sms_template_save" label="Edit" title={String(r.label)} testId={`sms-edit-${String(r.code)}`} payload={{ code: r.code }} done="Saved."
          fields={[{ name: 'body', label: 'Text', type: 'textarea', value: r.body, required: true, wide: true, hint: 'Name CarmaCars, keep {{link}}, no long dashes, 320 characters at most.' },
            { name: 'enabled', label: 'Send this text', type: 'bool', value: r.enabled }, { name: 'urgent', label: 'Urgent (also during the quiet hours)', type: 'bool', value: r.urgent }]} /> }]} />
    </Card>
  </>);
}
