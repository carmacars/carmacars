import { Act, SaveForm } from '@/features/admin/Act';
import { Card, Table } from '@/features/admin/ui';
import { CHANNEL_OPTIONS, fixedLabel, policyNow, textsSaved, type PolicyList, type PolicyType } from './model';

// r48 (2971): Program settings, Texts and email by message type: each type that can go by text, its texts in the last 30
// days and its channel; the switch "Email ready for production" (SES out of its sandbox) above it. The database decides
// (app.channel_policy_for); this only shows and changes it.
export function ChannelPolicyCard({ l, ready, refresh }: { l: PolicyList | null; ready: boolean; refresh: string }) {
  if (!l) return <Card title="Texts and email by message type" testId="channel-policy-card"><p className="small muted">The list could not be read. Reload the page.</p></Card>;
  const saved = textsSaved(l);
  return (
    <Card title="Texts and email by message type" testId="channel-policy-card">
      <p className="small muted">Texts cost money; email does not. Once email is ready for production, only the urgent messages keep their texts (the pickup details and codes, a late return, a failed payment, a declined deposit). Every other message goes by email, and by text only when the person has no email address or their email bounced. The deposit link, sign-in codes, staff alerts and texts typed by staff always stay texts. While the switch is off nothing changes.</p>
      <SaveForm table="program_settings" rowKey="current" testId="program-email-ready" label="Save" fields={[{ name: 'email_production_ready', label: 'Email ready for production (Amazon SES out of its sandbox)', type: 'bool', value: ready,
        hint: 'On: each message type below follows its channel. Off: as before, each person\'s own choice of text, email or both.' }]} />
      {ready && saved > 0 && <p className="small" data-testid="channel-policy-saved">About {saved} texts in the last 30 days were of types that now go by email.</p>}
      <Table<PolicyType & Record<string, unknown>> testId="channel-policy" sort={false} rows={l.types as Array<PolicyType & Record<string, unknown>>} rowKey={(r) => r.code} empty="No message types that can go by text." cols={[
        { key: 'label', label: 'Message', render: (r) => <>{r.label}<span className="small muted"> · {r.audience}</span></> },
        { key: 'texts_30d', label: 'Texts, last 30 days', num: true },
        { key: 'channel', label: 'Channel', render: (r) => <span className="small" data-testid={`channel-${r.code}`}>{policyNow(r, ready)}</span> },
        { key: 'code', label: '', render: (r) => <Act action="channel_policy_set" payload={{ code: r.code }} label="Change" testId={`channel-set-${r.code}`} refresh={[refresh]} done="Saved."
            fields={[{ name: 'channel', label: `${r.label}: send by`, type: 'select', options: CHANNEL_OPTIONS, value: r.channel, required: true }]} /> }
      ]} />
      {l.fixed.length > 0 && <details><summary className="small link">Texts that always stay texts ({l.fixed.reduce((a, x) => a + x.texts_30d, 0)} in the last 30 days)</summary>
        <ul className="small" data-testid="channel-policy-fixed">{l.fixed.map((x) => <li key={x.code}>{fixedLabel(x.code)}: {x.texts_30d}</li>)}</ul></details>}
    </Card>
  );
}
