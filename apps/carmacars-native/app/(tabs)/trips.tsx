import { Text, View } from 'react-native';
import { Image } from 'expo-image';
import { useRouter } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { carName, when } from '@/logic/format';
import { nextStep, sortTrips, STATUS_WORD, type TripLike } from '@/logic/trip';
import { color, radius, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Empty, Failed, H2, Notice, Row, Screen, Small } from '@/ui/kit';

// My trips: what is on now and coming up, each with the one thing it needs next, then the past ones.
type Trip = TripLike & { id: string; vehicle_year: number; vehicle_make: string; vehicle_model: string; cover: { url: string; alt: string | null } | null };

export default function Trips() {
  const { api, session } = useApp();
  const router = useRouter();
  const trips = useLoad<Trip[]>(session ? 'trips' : null, () => api.call('trips') as Promise<{ ok: true; data: Trip[] } | { ok: false; code: string; message: string }>);
  if (!session) return <Screen><Empty title="Your trips live here" body="Sign in to see your bookings, sign your agreement, pay and check in." action={<Button label="Sign in" onPress={() => router.push('/sign-in')} />} /></Screen>;
  if (trips.loading) return <Busy label="Loading your trips" />;
  if (!trips.data) return <Failed message={trips.error ?? 'Your trips could not be loaded.'} onRetry={trips.reload} />;
  const { current, past } = sortTrips(trips.data);
  const row = (b: Trip) => {
    const step = nextStep(b);
    return (
      <Card key={b.id} onPress={() => router.push(`/trip/${b.booking_number}` as never)} label={`${carName(b)}, ${STATUS_WORD[b.status] ?? b.status}`} testID={`trip-${b.booking_number}`}>
        <Row style={{ alignItems: 'flex-start', gap: space.md }}>
          {b.cover ? <Image source={{ uri: b.cover.url }} style={{ width: 84, height: 62, borderRadius: radius.sm }} contentFit="cover" accessibilityLabel={b.cover.alt ?? carName(b)} /> : null}
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={type.h3}>{carName(b)}</Text>
            <Small>{when(b.pickup_at)} to {when(b.return_at)}</Small>
            <Row style={{ marginTop: space.xs }}><Badge label={STATUS_WORD[b.status] ?? b.status} tone={b.status === 'on_rent' ? 'red' : b.status === 'confirmed' ? 'ok' : 'dark'} /><Small>{b.booking_number}</Small></Row>
          </View>
        </Row>
        {step.cta ? <Text style={[type.label, { color: color.red, marginTop: space.md }]}>{step.title} ›</Text> : null}
      </Card>
    );
  };
  return (
    <Screen onRefresh={trips.reload} refreshing={trips.refreshing} testID="trips">
      {trips.error ? <Notice tone="warn">{trips.error}</Notice> : null}
      {!current.length && !past.length ? <Empty title="No trips yet" body="Find a car and send a request: it shows here as soon as it is sent." action={<Button label="See the cars" onPress={() => router.push('/')} />} /> : null}
      {current.length ? <H2 style={{ marginTop: 0 }}>Now and coming up</H2> : null}
      {current.map(row)}
      {past.length ? <H2>Past trips</H2> : null}
      {past.map(row)}
    </Screen>
  );
}
