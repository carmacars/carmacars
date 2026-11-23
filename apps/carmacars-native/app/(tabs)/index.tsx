import { useMemo, useState } from 'react';
import { FlatList, Modal, StyleSheet, Text, View } from 'react-native';
import { Image } from 'expo-image';
import { useRouter } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import type { Available } from '@/shared';
import { money, torontoDay } from '@/logic/format';
import { activeCount, datesProblem, makeOptions, noFilters, searchCars, type Filters, type Hit, type Sort } from '@/logic/search';
import { color, radius, space, type } from '@/theme';
import { Appear, Badge, Busy, Button, Card, Chip, Empty, Failed, H2, Notice, Row, Screen, Small, Wrap } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';

// Cars: the fleet with the site's filters (type, seats, make, model family, transmission, daily rate) and, with dates
// chosen, only the cars that are free, at the price for those dates.
export default function Explore() {
  const { api, config } = useApp();
  const router = useRouter();
  const fleet = useLoad('cars', () => api.call('cars'));
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [filters, setFilters] = useState<Filters>(noFilters);
  const [sort, setSort] = useState<Sort>('recommended');
  const [panel, setPanel] = useState(false);
  const today = torontoDay();
  const problem = datesProblem(from || null, to || null, today, config?.rules.max_days ?? 30);
  const dated = !!from && !!to && !problem;
  const avail = useLoad<Available[]>(dated ? `avail:${from}:${to}` : null, () => api.call('cars.available', { body: { from, to, tf: undefined, tt: undefined } }));
  const cars = fleet.data?.cars ?? [];
  const hits = useMemo(() => searchCars(cars, filters, dated ? avail.data ?? [] : null, sort), [cars, filters, dated, avail.data, sort]);
  const opts = useMemo(() => makeOptions(cars, filters.make), [cars, filters.make]);
  const set = (p: Partial<Filters>) => setFilters((f) => ({ ...f, ...p }));
  const count = activeCount(filters);

  const head = (
    <View style={{ padding: space.lg, paddingBottom: 0 }}>
      <Row style={{ alignItems: 'flex-start' }}>
        <WhenField label="Pickup" mode="date" value={from} min={today} onChange={(v) => { setFrom(v); if (to && to <= v) setTo(''); }} testID="from" />
        <WhenField label="Return" mode="date" value={to} min={from || today} onChange={setTo} testID="to" />
      </Row>
      {problem ? <Notice tone="warn">{problem}</Notice> : null}
      <Row style={{ justifyContent: 'space-between', marginBottom: space.md }}>
        <Chip label={count ? `Filters (${count})` : 'Filters'} on={count > 0} onPress={() => setPanel(true)} testID="filters" />
        <Wrap>
          <Chip label="Price ↑" on={sort === 'price_low'} onPress={() => setSort(sort === 'price_low' ? 'recommended' : 'price_low')} />
          <Chip label="Price ↓" on={sort === 'price_high'} onPress={() => setSort(sort === 'price_high' ? 'recommended' : 'price_high')} />
        </Wrap>
      </Row>
      <Small style={{ marginBottom: space.sm }}>{dated && avail.loading ? 'Checking your dates…' : `${hits.length} car${hits.length === 1 ? '' : 's'}${dated ? ' free for your dates' : ''}`}</Small>
    </View>
  );

  if (fleet.loading) return <Busy label="Loading the cars" shape="cards" rows={2} />;
  if (!fleet.data) return <Failed message={fleet.error ?? 'The cars could not be loaded.'} onRetry={fleet.reload} />;
  return (
    <View style={{ flex: 1, backgroundColor: color.white }} testID="explore">
      <FlatList data={hits} keyExtractor={(h) => h.car.vehicle_id} ListHeaderComponent={head} onRefresh={fleet.reload} refreshing={fleet.refreshing} contentContainerStyle={{ paddingBottom: space.xxl }}
        ListEmptyComponent={dated && avail.loading ? <Busy /> : <Empty title="No cars match" body={dated ? 'Try other dates or fewer filters.' : 'Try fewer filters.'} action={count ? <Button label="Clear filters" variant="outline" onPress={() => setFilters(noFilters())} /> : undefined} />}
        renderItem={({ item, index }) => <CarRow hit={item} index={index} onPress={() => router.push({ pathname: '/car/[slug]', params: { slug: item.car.slug, from, to } } as never)} />} />
      <Modal visible={panel} animationType="slide" presentationStyle="pageSheet" onRequestClose={() => setPanel(false)}>
        <Screen footer={<><Button label={`Show ${hits.length} car${hits.length === 1 ? '' : 's'}`} onPress={() => setPanel(false)} testID="apply" /><Button label="Clear filters" variant="ghost" onPress={() => setFilters(noFilters())} /></>}>
          <H2 style={{ marginTop: 0 }}>Type</H2>
          <Wrap>{(fleet.data.classes ?? []).filter((c) => cars.some((x) => x.classes.includes(c.code))).map((c) => (
            <Chip key={c.code} label={c.label} on={filters.classes.includes(c.code)} onPress={() => set({ classes: filters.classes.includes(c.code) ? filters.classes.filter((x) => x !== c.code) : [...filters.classes, c.code] })} />))}</Wrap>
          <H2>Seats</H2>
          <Wrap>{[null, 4, 5, 7].map((n) => <Chip key={String(n)} label={n === null ? 'Any' : `${n}+`} on={filters.seats === n} onPress={() => set({ seats: n })} />)}</Wrap>
          <H2>Make</H2>
          <Wrap><Chip label="Any" on={!filters.make} onPress={() => set({ make: null, family: null, trim: null })} />{opts.makes.map((m) => <Chip key={m} label={m} on={filters.make === m} onPress={() => set({ make: m, family: null, trim: null })} />)}</Wrap>
          {filters.make && opts.families.length ? (<>
            <H2>Model</H2>
            <Wrap><Chip label="Any" on={!filters.family} onPress={() => set({ family: null, trim: null })} />{opts.families.map((f) => <Chip key={f.model} label={f.model} on={filters.family === f.model} onPress={() => set({ family: f.model, trim: null })} />)}</Wrap>
            {filters.family && (opts.families.find((f) => f.model === filters.family)?.trims.length ?? 0) > 1 ? (
              <Wrap style={{ marginTop: space.sm }}>{opts.families.find((f) => f.model === filters.family)!.trims.map((t) => <Chip key={t} label={t} on={filters.trim === t} onPress={() => set({ trim: filters.trim === t ? null : t })} />)}</Wrap>) : null}
          </>) : null}
          <H2>Transmission</H2>
          <Wrap>{([[null, 'Any'], ['automatic', 'Automatic'], ['manual', 'Manual']] as const).map(([v, l]) => <Chip key={l} label={l} on={filters.transmission === v} onPress={() => set({ transmission: v })} />)}</Wrap>
          <H2>Daily rate</H2>
          <Wrap>{[null, 7500, 10000, 15000, 25000].map((n) => <Chip key={String(n)} label={n === null ? 'Any' : `Up to ${money(n)}`} on={filters.maxDailyCents === n} onPress={() => set({ maxDailyCents: n })} />)}</Wrap>
        </Screen>
      </Modal>
    </View>
  );
}

function CarRow({ hit, index, onPress }: { hit: Hit; index: number; onPress: () => void }) {
  const c = hit.car;
  const name = `${c.year ? `${c.year} ` : ''}${c.make} ${hit.family}`;
  const rate = hit.quote?.daily_rate_cents ?? c.daily_rate_cents;
  return (
    <Appear delay={Math.min(index, 6) * 40} style={{ paddingHorizontal: space.lg }}>
      <Card onPress={onPress} label={`${name}, ${money(rate)} a day`} style={{ padding: 0, overflow: 'hidden' }} testID={`car-${c.slug}`}>
        {c.cover ? <Image source={{ uri: c.cover.url }} style={s.cover} contentFit="cover" transition={150} accessibilityLabel={c.cover.alt ?? name} /> : <View style={[s.cover, { backgroundColor: color.field }]} />}
        <View style={{ padding: space.lg }}>
          <Row style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <View style={{ flex: 1 }}>
              <Text style={type.h3}>{name}</Text>
              <Small>{[c.trim && c.trim !== hit.family ? c.trim : null, c.seats ? `${c.seats} seats` : null, c.transmission].filter(Boolean).join(' · ')}</Small>
            </View>
            <View style={{ alignItems: 'flex-end' }}>
              <Text style={[type.h3, { color: color.red, fontVariant: ['tabular-nums'] }]}>{money(rate)}</Text>
              <Small>a day</Small>
            </View>
          </Row>
          {hit.quote ? <Small style={{ marginTop: space.xs, color: color.ink }}>{money(hit.quote.total_cents)} for {hit.quote.billable_days} day{hit.quote.billable_days === 1 ? '' : 's'}, tax in</Small> : null}
          {c.insurance_included ? <View style={{ marginTop: space.sm }}><Badge label="Insurance included" tone="ok" /></View> : null}
        </View>
      </Card>
    </Appear>
  );
}
const s = StyleSheet.create({ cover: { width: '100%', aspectRatio: 16 / 10, borderTopLeftRadius: radius.lg, borderTopRightRadius: radius.lg } });
