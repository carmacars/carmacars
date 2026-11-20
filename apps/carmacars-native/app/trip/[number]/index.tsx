import { useState } from 'react';
import { Alert, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { carName, money, when } from '@/logic/format';
import { nextStep, STATUS_WORD } from '@/logic/trip';
import { loadTrip, type TripData } from '@/trip-data';
import { openSite } from '@/native';
import { color, space, type } from '@/theme';
import { Appear, Badge, Busy, Button, Card, Failed, Field, H2, Notice, Pair, Row, Screen, Small } from '@/ui/kit';

// One trip: where it stands, the one thing it needs next, the offer, the money, and everything else a trip has.
export default function TripScreen() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api, config, open } = useApp();
  const router = useRouter();
  const trip = useLoad<TripData>(`trip:${number}`, () => loadTrip(api, number));
  const { busy, error, act } = useAct();
  const [note, setNote] = useState('');
  const [asking, setAsking] = useState<'change' | 'decline' | null>(null);
  if (trip.loading) return <Busy label="Loading your trip" />;
  if (!trip.data) return <Failed message={trip.error ?? 'This trip could not be loaded.'} onRetry={trip.reload} />;
  const { booking: b, messages, self_checkin } = trip.data;
  const step = nextStep(b, { selfCheckin: self_checkin });
  const offer = b.status === 'offered' ? b.offers.find((o) => o.version === b.current_offer_version) ?? null : null;
  const site = (sub: string) => void openSite(`/account/bookings/${b.booking_number}${sub}`, config?.site_url);
  const again = () => { forgetLoaded('trips'); trip.reload(); };

  const answer = async (action: 'approve' | 'decline' | 'change') => {
    const r = await act(action, () => api.call('trip.offer', { params: { number }, body: { action, version: offer?.version, note: note.trim() || undefined } }));
    if (!r.ok) return;
    setAsking(null); setNote(''); again();
    if (action === 'approve') router.push(`/trip/${number}/sign` as never);
  };
  const approve = () => Alert.alert('Accept this offer?', `${money(offer?.renter_due_cents ?? offer?.total_cents ?? 0)} due to confirm, plus the refundable deposit. Next you sign the agreement.`, [{ text: 'Not yet', style: 'cancel' }, { text: 'Accept', onPress: () => void answer('approve') }]);

  return (
    <Screen onRefresh={again} refreshing={trip.refreshing} testID="trip">
      <Stack.Screen options={{ title: b.booking_number }} />
      <Text style={type.h1}>{carName(b)}</Text>
      <Row style={{ marginBottom: space.md }}><Badge label={STATUS_WORD[b.status] ?? b.status} tone={b.status === 'on_rent' ? 'red' : b.status === 'confirmed' ? 'ok' : 'dark'} /><Small>{b.booking_number}</Small></Row>
      {trip.error ? <Notice tone="warn">{trip.error}</Notice> : null}
      {error ? <Notice tone="bad">{error}</Notice> : null}

      {step.cta && step.key !== 'offer' && step.path ? (
        <Appear><Card style={{ borderColor: color.red, borderWidth: 1.5 }}>
          <Text style={type.h3}>{step.title}</Text>
          {b.sign_pay?.due_cents && (step.key === 'sign' || step.key === 'pay') ? <Small style={{ marginBottom: space.sm }}>{money(b.sign_pay.due_cents)} due to confirm</Small> : null}
          <Button label={step.cta} onPress={() => open(step.path!)} style={{ marginTop: space.sm, marginBottom: 0 }} testID="next-step" />
        </Card></Appear>
      ) : step.key === 'drivers' ? <Notice tone="warn">{step.title}. We emailed them their own link.</Notice> : null}

      {offer ? (
        <Card testID="offer">
          <Text style={type.h3}>Your offer</Text>
          {offer.expires_at ? <Small>Good until {when(offer.expires_at)}</Small> : null}
          {offer.message ? <Text style={[type.body, { marginVertical: space.sm }]}>{offer.message}</Text> : null}
          {(offer.line_items ?? []).map((l, i) => <Pair key={i} k={l.label ?? l.description ?? 'Charge'} v={money(l.amount_cents)} />)}
          <Pair k="Total" v={money(offer.total_cents)} strong />
          <Pair k="Refundable deposit" v={money(offer.deposit_cents)} />
          {asking ? (<>
            <Field label={asking === 'decline' ? 'Why are you declining? (optional)' : 'What should we change?'} value={note} onChangeText={setNote} multiline />
            <Button label={asking === 'decline' ? 'Decline the offer' : 'Ask for the change'} variant={asking === 'decline' ? 'danger' : 'dark'} onPress={() => void answer(asking)} busy={busy === asking} disabled={asking === 'change' && note.trim().length < 3} />
            <Button label="Cancel" variant="ghost" onPress={() => setAsking(null)} />
          </>) : (<>
            <Button label="Accept and sign" onPress={approve} busy={busy === 'approve'} style={{ marginTop: space.md }} testID="accept" />
            <Row><Button label="Ask for a change" variant="outline" onPress={() => setAsking('change')} style={{ flex: 1 }} /><Button label="Decline" variant="ghost" onPress={() => setAsking('decline')} style={{ flex: 1 }} /></Row>
          </>)}
        </Card>
      ) : null}

      <Card>
        <Pair k="Pickup" v={when(b.pickup_at)} />
        {b.pickup_place ? <Small style={{ textAlign: 'right' }}>{b.pickup_place}</Small> : null}
        <Pair k="Return" v={when(b.return_at)} />
        {b.return_place ? <Small style={{ textAlign: 'right' }}>{b.return_place}</Small> : null}
        {b.total_due_at_booking_cents ? <Pair k="Total" v={money(b.total_due_at_booking_cents)} strong /> : null}
        {b.deposit_cents ? <Pair k="Deposit" v={money(b.deposit_cents)} /> : null}
      </Card>

      {(b.still_needed?.items ?? []).length ? (
        <Card>
          <Text style={[type.h3, { marginBottom: space.sm }]}>Before pickup</Text>
          {b.still_needed!.items.map((i) => (
            <View key={i.key} style={{ paddingVertical: 4 }}>
              <Row style={{ justifyContent: 'space-between' }}>
                <View style={{ flex: 1 }}><Text style={type.body}>{i.label}</Text>{i.reason ? <Small style={{ color: color.red }}>{i.reason}</Small> : null}</View>
                <Badge label={i.status === 'done' ? 'Done' : i.status === 'review' ? 'Under review' : i.status === 'rejected' ? 'Not accepted' : 'Needed'} tone={i.status === 'done' ? 'ok' : i.status === 'review' ? 'muted' : 'red'} />
              </Row>
              {i.action && i.status !== 'done' && i.status !== 'review' ? <Button label={i.action.label} variant="outline" onPress={() => open(i.action!.path)} style={{ marginTop: space.xs, marginBottom: 0 }} testID={`need-${i.key}`} /> : null}
            </View>
          ))}
          <Button label="Licence and selfie with the camera" variant="ghost" onPress={() => router.push(`/trip/${number}/verify` as never)} style={{ marginTop: space.sm, marginBottom: 0 }} testID="go-verify" />
        </Card>
      ) : null}

      <Button label={`Messages${messages.length ? ` (${messages.length})` : ''}`} variant="outline" onPress={() => router.push(`/trip/${number}/chat` as never)} testID="go-chat" />
      {['confirmed', 'on_rent'].includes(b.status) ? <Button label="Extend this trip" variant="outline" onPress={() => router.push(`/trip/${number}/extend` as never)} testID="go-extend" /> : null}
      {b.status === 'on_rent' ? <Button label="Check out: I have returned the car" variant="dark" onPress={() => router.push(`/trip/${number}/checkout` as never)} testID="go-checkout" /> : null}
      {b.status === 'confirmed' && self_checkin ? <Button label="Check in at the car" variant="dark" onPress={() => router.push(`/trip/${number}/checkin` as never)} testID="go-checkin" /> : null}

      {b.payments.length ? (<>
        <H2>Payments</H2>
        {b.payments.map((p) => <Pair key={p.id} k={`${p.purpose.replace(/_/g, ' ')}${p.card_last4 ? ` · ${p.card_brand ?? 'card'} ${p.card_last4}` : ''}`} v={`${money(p.amount_cents)} · ${p.status}`} />)}
      </>) : null}
      <H2>More</H2>
      <Button label="Agreement and documents" variant="ghost" onPress={() => site('')} />
      <Button label="Change the dates" variant="ghost" onPress={() => site('/change')} />
      {['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) ? <Button label="Cancel this booking" variant="ghost" onPress={() => site('/cancel')} /> : null}
      {b.status === 'on_rent' ? <Button label="Accident or breakdown" variant="danger" onPress={() => site('/accident-card')} /> : null}
    </Screen>
  );
}
