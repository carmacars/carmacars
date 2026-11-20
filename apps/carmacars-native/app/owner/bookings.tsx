import { Text, View } from 'react-native';
import { Stack } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { money, when } from '@/logic/format';
import { type } from '@/theme';
import { Badge, Busy, Card, Empty, Failed, Row, Screen, Small } from '@/ui/kit';

// The bookings of an owner's cars: what is out, what is coming, what came back. The database shows the owner only what
// their agreement lets them see (an amount is hidden where the plan hides it).
interface OwnerBooking { booking_id: string; booking_number: string | null; status: string; vehicle_name: string; pickup_at: string; return_at: string; rental_charge_cents: number | null; renter_name: string | null }
const WORD: Record<string, string> = { confirmed: 'Booked', on_rent: 'On rent', returned: 'Returned', closed: 'Completed', pending_payment: 'Awaiting payment', cancelled: 'Cancelled' };

export default function OwnerBookings() {
  const { api } = useApp();
  const list = useLoad<OwnerBooking[]>('owner.bookings', () => api.call('owner.bookings') as Promise<{ ok: true; data: OwnerBooking[] } | { ok: false; code: string; message: string }>);
  if (list.loading) return <Busy label="Loading bookings" />;
  if (!list.data) return <Failed message={list.error ?? 'The bookings could not be loaded.'} onRetry={list.reload} />;
  const rows = [...list.data].sort((a, b) => b.pickup_at.localeCompare(a.pickup_at));
  return (
    <Screen onRefresh={list.reload} refreshing={list.refreshing} testID="owner-bookings">
      <Stack.Screen options={{ title: 'Bookings' }} />
      {!rows.length ? <Empty title="No bookings yet" body="Bookings of your cars show here as they are made." /> : rows.map((b) => (
        <Card key={b.booking_id}>
          <Row style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <View style={{ flex: 1 }}>
              <Text style={type.h3}>{b.vehicle_name}</Text>
              <Small>{when(b.pickup_at)} to {when(b.return_at)}</Small>
              <Small>{[b.booking_number, b.renter_name].filter(Boolean).join(' · ')}</Small>
            </View>
            <View style={{ alignItems: 'flex-end', gap: 4 }}>
              <Badge label={WORD[b.status] ?? b.status} tone={b.status === 'on_rent' ? 'red' : b.status === 'confirmed' ? 'ok' : 'muted'} />
              {b.rental_charge_cents !== null ? <Text style={type.h3}>{money(b.rental_charge_cents)}</Text> : null}
            </View>
          </Row>
        </Card>
      ))}
    </Screen>
  );
}
