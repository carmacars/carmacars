import { useState } from 'react';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { money, when } from '@/logic/format';
import { loadTrip, type TripData } from '@/trip-data';
import { Busy, Button, Card, Failed, Field, H2, Notice, P, Pair, Row, Screen, Small } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';

// Extend a trip: pick the new return, see what it costs before asking, then ask. An approved extension is paid with
// the card on file, here.
export default function Extend() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api } = useApp();
  const router = useRouter();
  const trip = useLoad<TripData>(`trip:${number}`, () => loadTrip(api, number));
  const { busy, error, act } = useAct();
  const [day, setDay] = useState('');
  const [time, setTime] = useState('');
  const [note, setNote] = useState('');
  const [preview, setPreview] = useState<Record<string, unknown> | null>(null);
  const [sent, setSent] = useState(false);
  if (trip.loading) return <Busy />;
  if (!trip.data) return <Failed message={trip.error ?? 'Not loaded.'} onRetry={trip.reload} />;
  const b = trip.data.booking;
  const ret = new Date(b.return_at);
  // the wall-clock the renter picks is Toronto time, as everywhere on the site
  const newReturn = day ? `${day}T${time || new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Toronto', hour: '2-digit', minute: '2-digit' }).format(ret)}` : '';
  const price = async () => { setPreview(null); const r = await act('preview', () => api.call('trip.extendPreview', { params: { number }, body: { newReturn } })); if (r.ok) setPreview(r.data as Record<string, unknown>); };
  const ask = async () => { const r = await act('ask', () => api.call('trip.extend', { params: { number }, body: { newReturn, note: note.trim() || undefined } })); if (r.ok) { setSent(true); forgetLoaded('trip'); trip.reload(); } };
  const payFor = async (id: string) => { const r = await act(`pay-${id}`, () => api.call('trip.extendPay', { params: { number, id } })); if (r.ok) { forgetLoaded('trip'); trip.reload(); } };
  const open = b.extensions.filter((e) => ['requested', 'approved'].includes(e.status));
  const cents = (k: string) => (typeof preview?.[k] === 'number' ? (preview[k] as number) : null);

  return (
    <Screen testID="extend" onRefresh={trip.reload} refreshing={trip.refreshing}>
      <Stack.Screen options={{ title: 'Extend' }} />
      <P>Your return is {when(b.return_at)}.</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {open.map((e) => (
        <Card key={e.id}>
          <Pair k="New return" v={when(e.new_return_at)} />
          {e.total_cents !== null ? <Pair k="Cost" v={money(e.total_cents)} strong /> : null}
          {e.status === 'approved' ? <Button label={`Pay ${money(e.total_cents)} with the card on file`} onPress={() => void payFor(e.id)} busy={busy === `pay-${e.id}`} testID="pay-extension" /> : <Small>Waiting for our answer. You get an alert.</Small>}
        </Card>
      ))}
      {sent ? <Notice tone="ok" title="Asked">We check the car is free and answer shortly.</Notice> : (<>
        <H2>New return</H2>
        <Row style={{ alignItems: 'flex-start' }}>
          <WhenField label="Date" mode="date" value={day} min={b.return_at.slice(0, 10)} onChange={(v) => { setDay(v); setPreview(null); }} testID="new-day" />
          <WhenField label="Time" mode="time" value={time} onChange={(v) => { setTime(v); setPreview(null); }} />
        </Row>
        <Button label="See the price" variant="outline" onPress={() => void price()} busy={busy === 'preview'} disabled={!day} testID="preview" />
        {preview ? (
          <Card>
            {cents('new_days') !== null ? <Pair k="Extra days" v={String(cents('new_days'))} /> : null}
            {cents('rental_charge_cents') !== null ? <Pair k="Rental" v={money(cents('rental_charge_cents'))} /> : null}
            {cents('hst_cents') !== null ? <Pair k="HST" v={money(cents('hst_cents'))} /> : null}
            {cents('total_cents') !== null ? <Pair k="Total" v={money(cents('total_cents'))} strong /> : null}
            {typeof preview.message === 'string' ? <Small>{preview.message}</Small> : null}
            {preview.available === false ? <Notice tone="bad">The car is not free until then. Try an earlier return.</Notice> : (<>
              <Field label="Note (optional)" value={note} onChangeText={setNote} maxLength={500} />
              <Button label="Ask to extend" onPress={() => void ask()} busy={busy === 'ask'} testID="ask" />
            </>)}
          </Card>
        ) : null}
      </>)}
      <Button label="Back to my trip" variant="ghost" onPress={() => router.back()} />
    </Screen>
  );
}
