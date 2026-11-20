import { Text, View } from 'react-native';
import { Image } from 'expo-image';
import { useRouter } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { money, when } from '@/logic/format';
import { openSite } from '@/native';
import { radius, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Empty, Failed, H2, Pair, Row, Screen, Small } from '@/ui/kit';

// My cars, for an owner: each car and what it is doing now, the month so far, and the statements.
interface Vehicle { vehicle_id: string; name?: string; year?: number | null; make?: string; model?: string; plate?: string | null }
interface Home { home: { owner: { legal_name?: string }; vehicles: Vehicle[]; statements: Array<{ id: string; statement_number: string; statement_month: string; payout_date: string; status: string; payout_cents: number }>; next_payout_date: string };
  live: Record<string, { key: string; label: string; tone: string }>; photo: Record<string, { url: string; alt: string } | null>;
  month_to_date: { final?: boolean; totals?: { payout_cents?: number; net_earnings_cents?: number; owner_revenue_cents?: number } } | null }
const month = (iso: string) => new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export default function OwnerTab() {
  const { api, config } = useApp();
  const router = useRouter();
  const o = useLoad<Home>('owner.home', () => api.call('owner.home') as Promise<{ ok: true; data: Home } | { ok: false; code: string; message: string }>);
  if (o.loading) return <Busy label="Loading your cars" />;
  if (!o.data) return <Failed message={o.error ?? 'Your cars could not be loaded.'} onRetry={o.reload} />;
  const { home, live, photo, month_to_date: mtd } = o.data;
  return (
    <Screen onRefresh={o.reload} refreshing={o.refreshing} testID="owner">
      {mtd ? (
        <Card>
          <Text style={type.h3}>This month so far{mtd.final ? '' : ' (not final)'}</Text>
          {typeof mtd.totals?.owner_revenue_cents === 'number' ? <Pair k="Rentals of your cars" v={money(mtd.totals.owner_revenue_cents)} /> : null}
          {typeof mtd.totals?.net_earnings_cents === 'number' ? <Pair k="Your earnings" v={money(mtd.totals.net_earnings_cents)} /> : null}
          {typeof mtd.totals?.payout_cents === 'number' ? <Pair k="Payout" v={money(mtd.totals.payout_cents)} strong /> : null}
          <Small>Next payout: {when(home.next_payout_date, false)}</Small>
        </Card>
      ) : null}
      <H2 style={{ marginTop: 0 }}>Cars</H2>
      {!home.vehicles.length ? <Empty title="No cars yet" body="Your cars show here once they are set up." /> : null}
      {home.vehicles.map((v) => {
        const name = v.name ?? [v.year, v.make, v.model].filter(Boolean).join(' ');
        const l = live[v.vehicle_id];
        const p = photo[v.vehicle_id];
        return (
          <Card key={v.vehicle_id}>
            <Row style={{ gap: space.md }}>
              {p ? <Image source={{ uri: p.url }} style={{ width: 84, height: 62, borderRadius: radius.sm }} contentFit="cover" accessibilityLabel={p.alt || name} /> : null}
              <View style={{ flex: 1, gap: 3 }}>
                <Text style={type.h3}>{name}</Text>
                {v.plate ? <Small>{v.plate}</Small> : null}
                {l ? <Badge label={l.label} tone={l.key === 'on_rent' ? 'red' : l.key === 'available' ? 'ok' : 'muted'} /> : null}
              </View>
            </Row>
          </Card>
        );
      })}
      <Button label="Bookings of my cars" variant="outline" onPress={() => router.push('/owner/bookings' as never)} testID="owner-bookings" />
      <H2>Statements</H2>
      {!home.statements.length ? <Small>Your first statement shows here after your first month.</Small> : null}
      {home.statements.slice(0, 12).map((st) => (
        <Card key={st.id} onPress={() => router.push(`/owner/statement/${st.id}` as never)} label={`Statement ${month(st.statement_month)}`}>
          <Row style={{ justifyContent: 'space-between' }}>
            <View><Text style={type.h3}>{month(st.statement_month)}</Text><Small>{st.statement_number} · paid {when(st.payout_date, false)}</Small></View>
            <Text style={type.h3}>{money(st.payout_cents)}</Text>
          </Row>
        </Card>
      ))}
      <Button label="Invoices, documents and settings on carmacars.ca" variant="ghost" onPress={() => void openSite('/owner', config?.site_url)} />
    </Screen>
  );
}
