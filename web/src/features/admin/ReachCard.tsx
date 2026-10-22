import { Act } from './Act';
import { Card, Kv, t } from './ui';
import { CHANNEL_LABEL, CHANNELS, whyNotWords, type Reach } from '@/features/phone/alerts';
import { formatPhone } from '@/features/auth/phone';

// Text alerts (migration 0096): a renter's, owner's or investor's channel on their Admin page. Staff see what the
// person chose, what is used now and why, their STOP and START history, and may change the choice (audit log).
export function ReachCard({ reach, who }: { reach: Reach | null; who: { renter_id?: string; owner_id?: string; investor_id?: string } }) {
  if (!reach) return null;
  const why = whyNotWords(reach.why_not, null, 'they');
  const stops = reach.log ?? [];
  return (
    <Card title="How we reach them" testId="reach-card"
      aside={<Act ops label="Change" submitLabel="Save" title="How should we reach them?" testId="reach-change" payload={who} done="Saved."
        fields={[{ name: 'channel', label: 'Channel', type: 'select', value: reach.chosen ?? '', options: [['', `Default (${CHANNEL_LABEL[reach.default]})`], ...CHANNELS.map((c) => [c, CHANNEL_LABEL[c]] as [string, string])],
          hint: 'Text and Both need a phone they verified with a code. Documents, statements and receipts are always emailed when there is an email.' }]} action="notify_channel_set" />}>
      <Kv rows={[
        ['Chosen', reach.chosen ? CHANNEL_LABEL[reach.chosen] : `Not chosen (default ${CHANNEL_LABEL[reach.default]})`],
        ['Used now', <span key="n" data-testid="reach-now">{CHANNEL_LABEL[reach.channel]}</span>],
        ['Verified phone', reach.phone ? formatPhone(reach.phone) : 'None'],
        ['Email', reach.email ?? 'None'],
        ['Why not text', why ?? ''],
        ['Texts in 30 days', reach.texts_30d !== undefined ? String(reach.texts_30d) : ''],
        ['STOP and START', stops.length ? stops.map((s) => `${s.action === 'stop' ? 'STOP' : 'START'} ${t(s.at)}${s.confirmation ? (s.confirmation === 'sent' ? ', confirmed by text' : `, confirmation ${s.confirmation}`) : ''}`).join(', ') : '']
      ]} />
    </Card>
  );
}
