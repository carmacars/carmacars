import { useRef, useState } from 'react';
import { Dimensions, FlatList, Text, View, type NativeScrollEvent, type NativeSyntheticEvent } from 'react-native';
import { Image } from 'expo-image';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { money, torontoDay } from '@/logic/format';
import { datesProblem, familyOf } from '@/logic/search';
import { color, space, type } from '@/theme';
import { Badge, Busy, Button, Failed, H2, Notice, P, Pair, Row, Screen, Small, Wrap } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';

// A car: its photos to swipe through, what it is, what it costs for your dates, and the button to ask for it.
interface Quote { lines: Array<{ label?: string; description?: string; amount_cents: number }>; hst_cents: number; total_cents: number; deposit_cents: number; billable_days: number; km_allowance_total: number;
  available: boolean; problems: Array<{ code: string; message: string }> }
type Car = { vehicle_id: string; slug: string; make: string; model: string; trim?: string | null; year?: number | null; seats?: number | null; transmission?: string | null; fuel?: string | null; doors?: number | null;
  daily_rate_cents?: number; deposit_cents?: number; km_allowance_per_day?: number; description?: string | null; features?: string[]; insurance_included?: boolean; home_area?: string | null; taking_requests?: boolean; car_code?: string | null };

export default function CarScreen() {
  const p = useLocalSearchParams<{ slug: string; from?: string; to?: string }>();
  const { api, config } = useApp();
  const router = useRouter();
  const page = useLoad(`car:${p.slug}`, () => api.call('car', { params: { slug: p.slug } }));
  const [from, setFrom] = useState(p.from ?? '');
  const [to, setTo] = useState(p.to ?? '');
  const [at, setAt] = useState(0);
  const width = Dimensions.get('window').width;
  const today = torontoDay();
  const problem = datesProblem(from || null, to || null, today, config?.rules.max_days ?? 30);
  const dated = !!from && !!to && !problem;
  const quote = useLoad<Quote>(dated ? `quote:${p.slug}:${from}:${to}` : null, () => api.call('car.quote', { params: { slug: p.slug }, body: { from, to, tf: undefined, tt: undefined, options: undefined } }) as Promise<{ ok: true; data: Quote } | { ok: false; code: string; message: string }>);
  const list = useRef<FlatList>(null);

  if (page.loading) return <Busy label="Loading the car" />;
  if (!page.data) return <Failed message={page.error ?? 'This car could not be loaded.'} onRetry={page.reload} />;
  const car = page.data.car as Car;
  const fam = familyOf({ make: car.make, model: car.model, trim: car.trim ?? null });
  const name = `${car.year ? `${car.year} ` : ''}${car.make} ${fam.model}`;
  const photos = page.data.photos;
  const onScroll = (e: NativeSyntheticEvent<NativeScrollEvent>) => setAt(Math.round(e.nativeEvent.contentOffset.x / width));
  const q = quote.data;
  const canAsk = car.taking_requests !== false;

  return (
    <Screen padded={false} testID="car" footer={<Button label={dated ? 'Request to book' : 'Choose your dates to book'} disabled={!canAsk || (dated && q ? !q.available : false)}
      onPress={() => router.push({ pathname: '/book/[slug]', params: { slug: car.slug, from, to } } as never)} testID="book" />}>
      <Stack.Screen options={{ title: name }} />
      {photos.length ? (
        <View>
          <FlatList ref={list} data={photos} horizontal pagingEnabled showsHorizontalScrollIndicator={false} keyExtractor={(ph, i) => `${i}-${ph.url}`} onMomentumScrollEnd={onScroll}
            accessibilityLabel={`Photos of the ${name}: ${photos.length}. Swipe to see the next one.`}
            renderItem={({ item, index }) => <Image source={{ uri: item.url }} style={{ width, aspectRatio: 4 / 3, backgroundColor: color.field }} contentFit="cover" transition={150} accessibilityLabel={item.alt ?? `${name}, photo ${index + 1} of ${photos.length}`} />} />
          <View style={{ position: 'absolute', right: space.md, bottom: space.md }}><Badge label={`${at + 1} / ${photos.length}`} /></View>
        </View>
      ) : <View style={{ width, aspectRatio: 4 / 3, backgroundColor: color.field }} />}
      <View style={{ padding: space.lg }}>
        <Text style={type.h1}>{name}</Text>
        <Small>{[fam.trim, car.car_code].filter(Boolean).join(' · ')}</Small>
        <Wrap style={{ marginVertical: space.md }}>
          {car.seats ? <Badge label={`${car.seats} seats`} tone="muted" /> : null}
          {car.transmission ? <Badge label={car.transmission} tone="muted" /> : null}
          {car.fuel ? <Badge label={car.fuel} tone="muted" /> : null}
          {car.insurance_included ? <Badge label="Insurance included" tone="ok" /> : null}
        </Wrap>
        {!canAsk ? <Notice tone="warn">This car is not taking requests right now.</Notice> : null}
        <Row style={{ alignItems: 'flex-start' }}>
          <WhenField label="Pickup" mode="date" value={from} min={today} onChange={(v) => { setFrom(v); if (to && to <= v) setTo(''); }} />
          <WhenField label="Return" mode="date" value={to} min={from || today} onChange={setTo} />
        </Row>
        {problem ? <Notice tone="warn">{problem}</Notice> : null}
        {dated && quote.loading ? <Busy label="Pricing your dates" /> : null}
        {dated && quote.error && !q ? <Notice tone="bad">{quote.error}</Notice> : null}
        {dated && q ? (
          <View>
            {!q.available ? <Notice tone="bad" title="Not free for these dates">{q.problems[0]?.message ?? 'Try other dates.'}</Notice> : null}
            {q.lines.map((l, i) => <Pair key={i} k={l.label ?? l.description ?? 'Charge'} v={money(l.amount_cents)} />)}
            <Pair k="HST" v={money(q.hst_cents)} />
            <Pair k={`Total for ${q.billable_days} day${q.billable_days === 1 ? '' : 's'}`} v={money(q.total_cents)} strong />
            <Small>Refundable deposit {money(q.deposit_cents)} · {q.km_allowance_total.toLocaleString('en-CA')} km included</Small>
          </View>
        ) : !dated && typeof car.daily_rate_cents === 'number' ? <Pair k="From" v={`${money(car.daily_rate_cents)} a day`} strong /> : null}
        {car.description ? (<><H2>About this car</H2><P>{car.description}</P></>) : null}
        {(car.features ?? []).length ? (<><H2>Features</H2><Wrap>{car.features!.slice(0, 24).map((f) => <Badge key={f} label={f} tone="muted" />)}</Wrap></>) : null}
        <H2>Pickup</H2>
        <P>{page.data.places?.owner_location ? `At the car's home${page.data.places.area ? ` in ${page.data.places.area}` : ''}, at our location, or at the airport.` : 'At our location or at the airport.'} You choose when you ask.</P>
        <Small>You send a request; we confirm the car and send your offer. Nothing is charged until you accept it.</Small>
      </View>
    </Screen>
  );
}
