import { useState } from 'react';
import { Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { useAct, useApp, useLoad } from '@/app-state';
import { ago } from '@/logic/format';
import { space, type } from '@/theme';
import { Badge, Busy, Button, Card, Chip, Empty, Failed, Notice, Row, Screen, Small, Wrap } from '@/ui/kit';

// Leads for Sales: the pool and my own, claimed with one tap (the database holds the claim rules and the cap). Phone
// numbers are masked exactly as on the site; calling and texting go through the platform from the lead's screen.
export interface LeadRow { id: string; type: 'renter' | 'owner' | 'partner'; source: string; name: string | null; phone: string | null; email: string | null; excerpt: string; vehicle: string | null; created_at: string;
  status: string; outcome: string | null; claim: { name: string; until: string; mine: boolean } | null; hold?: { name: string; locked: boolean } | null; hot: boolean; new: boolean }
interface Leads { leads: { rows: LeadRow[]; count: number; mine_active: number; max_active: number; next_claim_at?: string | null }; dashboard: { today: { claimed: number; won: number }; open_pool: number } | null }
const VIEWS: Array<[string, string, Record<string, string>]> = [['open', 'Open', {}], ['mine', 'Mine', { mine: '1' }], ['new', 'New', { status: 'new' }], ['unclaimed', 'Not claimed', { status: 'unclaimed' }]];

export default function LeadsTab() {
  const { api } = useApp();
  const router = useRouter();
  const [view, setView] = useState('open');
  const q = VIEWS.find(([k]) => k === view)![2];
  const list = useLoad<Leads>(`sales.leads:${view}`, () => api.call('sales.leads', { query: q }) as Promise<{ ok: true; data: Leads } | { ok: false; code: string; message: string }>);
  const { busy, error, act } = useAct();
  const claim = async (id: string) => { const r = await act(id, () => api.call('sales.leadAct', { body: { action: 'lead_claim', p: { lead: id } } })); if (r.ok) list.reload(); };
  if (list.loading) return <Busy label="Loading leads" />;
  if (!list.data) return <Failed message={list.error ?? 'The leads could not be loaded.'} onRetry={list.reload} />;
  const d = list.data.leads;
  return (
    <Screen onRefresh={list.reload} refreshing={list.refreshing} testID="leads">
      <Wrap style={{ marginBottom: space.md }}>{VIEWS.map(([k, label]) => <Chip key={k} label={label} on={view === k} onPress={() => setView(k)} />)}</Wrap>
      <Small style={{ marginBottom: space.md }}>You hold {d.mine_active} of {d.max_active} leads{list.data.dashboard ? ` · ${list.data.dashboard.open_pool} in the pool · ${list.data.dashboard.today.won} won today` : ''}</Small>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {!d.rows.length ? <Empty title="No leads here" body="New leads arrive as alerts when Leads alerts are on in Profile." /> : null}
      {d.rows.map((l) => (
        <Card key={l.id} onPress={() => router.push(`/sales/lead/${l.id}` as never)} label={`Lead ${l.name ?? 'without a name'}`} testID={`lead-${l.id}`}>
          <Row style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <View style={{ flex: 1 }}>
              <Text style={type.h3}>{l.name ?? 'No name yet'}</Text>
              <Small>{[l.type === 'owner' ? 'Owner lead' : l.type === 'partner' ? 'Partner lead' : 'Renter lead', l.source, ago(l.created_at)].join(' · ')}</Small>
            </View>
            <Row>{l.hot ? <Badge label="Hot" tone="red" /> : null}{l.new ? <Badge label="New" /> : null}</Row>
          </Row>
          {l.vehicle ? <Text style={[type.body, { marginTop: space.xs }]}>{l.vehicle}</Text> : null}
          {l.excerpt ? <Small style={{ marginTop: space.xs }}>{l.excerpt}</Small> : null}
          {l.claim ? <Small style={{ marginTop: space.sm }}>{l.claim.mine ? 'Yours' : `Claimed by ${l.claim.name}`}</Small>
            : l.hold?.locked ? <Small style={{ marginTop: space.sm }}>{l.hold.name} is handling a call</Small>
              : <Button label="Claim" onPress={() => void claim(l.id)} busy={busy === l.id} style={{ marginTop: space.md, marginBottom: 0 }} testID={`claim-${l.id}`} />}
        </Card>
      ))}
    </Screen>
  );
}
