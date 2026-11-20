import { Text } from 'react-native';
import { Stack, useLocalSearchParams } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { money, when } from '@/logic/format';
import { openSite } from '@/native';
import { type } from '@/theme';
import { Busy, Button, Card, Failed, H2, Line, Notice, Pair, Screen, Small } from '@/ui/kit';

// One monthly statement: what the cars earned, what came off, and the payout.
interface StatementLine { label?: string; description?: string; amount_cents: number }
interface Statement { statement: { statement_number: string; statement_month: string; payout_date: string; status: string; is_final: boolean; owner_revenue_cents: number; revenue_share_cents: number; net_earnings_cents: number;
  deductions_cents: number; hst_on_payout_cents: number; balance_brought_forward_cents: number; payout_cents: number; balance_carried_forward_cents: number };
  vehicles: Array<{ vehicle_id: string; name: string; plate: string | null; lines: StatementLine[] }>; owner_lines: StatementLine[];
  payout: { amount_cents: number; status: string; method: string; paid_at: string | null; scheduled_for: string } | null }

export default function StatementScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { api, config } = useApp();
  const st = useLoad<Statement>(`owner.statement:${id}`, () => api.call('owner.statement', { params: { id } }) as Promise<{ ok: true; data: Statement } | { ok: false; code: string; message: string }>);
  if (st.loading) return <Busy label="Loading the statement" />;
  if (!st.data) return <Failed message={st.error ?? 'This statement could not be loaded.'} onRetry={st.reload} />;
  const { statement: s, vehicles, owner_lines, payout } = st.data;
  const month = new Date(`${s.statement_month.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' });
  return (
    <Screen onRefresh={st.reload} refreshing={st.refreshing} testID="statement">
      <Stack.Screen options={{ title: s.statement_number }} />
      <Text style={type.h1}>{month}</Text>
      {!s.is_final ? <Notice tone="warn">Not final yet: the month is still open.</Notice> : null}
      <Card>
        <Pair k="Rentals of your cars" v={money(s.owner_revenue_cents)} />
        <Pair k="Your share" v={money(s.revenue_share_cents)} />
        {s.deductions_cents ? <Pair k="Deductions" v={money(-Math.abs(s.deductions_cents))} /> : null}
        {s.hst_on_payout_cents ? <Pair k="HST" v={money(s.hst_on_payout_cents)} /> : null}
        {s.balance_brought_forward_cents ? <Pair k="Brought forward" v={money(s.balance_brought_forward_cents)} /> : null}
        <Line />
        <Pair k="Payout" v={money(s.payout_cents)} strong />
        {payout ? <Small>{payout.paid_at ? `Paid ${when(payout.paid_at, false)}` : `Scheduled for ${when(payout.scheduled_for, false)}`} · {payout.method.replace(/_/g, ' ')}</Small> : <Small>Payout date: {when(s.payout_date, false)}</Small>}
        {s.balance_carried_forward_cents ? <Pair k="Carried forward" v={money(s.balance_carried_forward_cents)} /> : null}
      </Card>
      {vehicles.map((v) => (
        <Card key={v.vehicle_id}>
          <Text style={type.h3}>{v.name}{v.plate ? ` · ${v.plate}` : ''}</Text>
          {v.lines.map((l, i) => <Pair key={i} k={l.label ?? l.description ?? 'Line'} v={money(l.amount_cents)} />)}
        </Card>
      ))}
      {owner_lines.length ? <H2>Other lines</H2> : null}
      {owner_lines.map((l, i) => <Pair key={i} k={l.label ?? l.description ?? 'Line'} v={money(l.amount_cents)} />)}
      <Button label="Download the PDF on carmacars.ca" variant="outline" onPress={() => void openSite(`/owner/statements/${id}`, config?.site_url)} />
    </Screen>
  );
}
