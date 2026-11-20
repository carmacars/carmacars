import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useAct, useApp } from '@/app-state';
import { money, torontoDay } from '@/logic/format';
import { openSite } from '@/native';
import { space, type } from '@/theme';
import { Busy, Button, Card, Check, Chip, Field, H2, Notice, Pair, Row, Screen, Small, Wrap } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';

// Send an offer from the phone: who it is for, the car, the dates, how it is covered. The price is the rate sheet's,
// worked out by the database (the same preview as the site's offer page); it is sent by email and text with the renter's
// link to accept, sign and pay. Prices set by hand, delivery and add-ons stay on the site's composer.
interface Car { id: string; name: string; plate: string | null; daily_rate_cents: number | null; free: boolean | null }
interface Form { role: string; offer_hours: number; text_enabled: boolean; cars: Car[] }
interface Found { id: string; legal_name: string; email: string | null; mobile: string | null; is_blocked: boolean }
interface Priced { ok: boolean; error?: string; available: boolean; booking: { billable_days: number; rental_charge_cents: number; deposit_cents: number; total_due_at_booking_cents: number; renter_due_at_booking_cents: number | null } }
// the wall-clock times typed here are Toronto time; the server takes instants
const instant = (day: string, time: string) => {
  const guess = new Date(`${day}T${time}:00Z`);
  const shown = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Toronto', hour: '2-digit', minute: '2-digit', day: '2-digit', hour12: false }).formatToParts(guess);
  const h = Number(shown.find((p) => p.type === 'hour')!.value) % 24; const m = Number(shown.find((p) => p.type === 'minute')!.value); const d = Number(shown.find((p) => p.type === 'day')!.value);
  let diff = (guess.getUTCHours() * 60 + guess.getUTCMinutes()) - (h * 60 + m);
  if (d !== guess.getUTCDate()) diff += d < guess.getUTCDate() || d > guess.getUTCDate() + 1 ? 1440 : -1440;
  return new Date(guess.getTime() + diff * 60_000).toISOString();
};

export default function OfferScreen() {
  const p = useLocalSearchParams<{ lead?: string; name?: string; email?: string }>();
  const { api, config } = useApp();
  const router = useRouter();
  const { busy, error, act } = useAct();
  const [form, setForm] = useState<Form | null>(null);
  const [q, setQ] = useState(p.name ?? '');
  const [found, setFound] = useState<Found[]>([]);
  const [renter, setRenter] = useState<Found | null>(null);
  const [fresh, setFresh] = useState({ full_name: p.name ?? '', email: p.email ?? '', mobile: '', date_of_birth: '' });
  const [from, setFrom] = useState(''); const [to, setTo] = useState(''); const [tf, setTf] = useState('10:00'); const [tt, setTt] = useState('10:00');
  const [car, setCar] = useState<string | null>(null);
  const [coverage, setCoverage] = useState<'1' | '3'>('3');
  const [choice, setChoice] = useState<'' | 'sourced' | 'for_carmacars'>('');
  const [message, setMessage] = useState('');
  const [byText, setByText] = useState(true); const [byEmail, setByEmail] = useState(true);
  const [priced, setPriced] = useState<Priced | null>(null);
  const [sent, setSent] = useState<{ booking_number: string; total_cents: number; notified: boolean } | null>(null);
  const dated = !!from && !!to && to >= from;

  useEffect(() => {
    void act('form', () => api.call('sales.offerRead', { body: { what: 'offer_form', p: dated ? { pickup_at: instant(from, tf), return_at: instant(to, tt) } : {} } })).then((r) => { if (r.ok) setForm(r.data as Form); });
  }, [from, to, tf, tt]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (q.trim().length < 3 || renter) { setFound([]); return; }
    const t = setTimeout(() => { void api.call('sales.offerRead', { body: { what: 'find_customers', p: { q: q.trim() } } }).then((r) => { if (r.ok) setFound((r.data as Found[]) ?? []); }); }, 350);
    return () => clearTimeout(t);
  }, [q, renter, api]);

  const who = renter ? { renter_id: renter.id } : { renter: { full_name: fresh.full_name.trim(), email: fresh.email.trim(), mobile: fresh.mobile.trim(), date_of_birth: fresh.date_of_birth } };
  const mobile = renter?.mobile ?? fresh.mobile;
  const text = byText && mobile.replace(/\D/g, '').length >= 10;
  const payload = () => ({ ...who, vehicle_id: car, pickup_at: instant(from, tf), return_at: instant(to, tt),
    pickup_location: { kind: 'our_location', address: null, distance_km: null, airport_code: null }, return_location: { kind: 'our_location', address: null, distance_km: null, airport_code: null },
    coverage_option: Number(coverage), source: 'phone', ...(choice ? { sales_choice: choice } : {}), rental_pay_method: 'card', deposit_pay_method: 'card', message: message.trim() || null, note: p.lead ? `From lead ${p.lead}` : null,
    expires_at: new Date(Date.now() + Math.max(1, form?.offer_hours ?? 24) * 3_600_000).toISOString(), notify: byEmail || byText, channels: { email: byEmail || (byText && !text), text } });
  const whoOk = !!renter || (fresh.full_name.trim().length > 2 && (/^\S+@\S+\.\S+$/.test(fresh.email.trim()) || fresh.mobile.replace(/\D/g, '').length >= 10) && /^\d{4}-\d{2}-\d{2}$/.test(fresh.date_of_birth));
  // Sales says whose client this is (it decides the commission): the database refuses an offer without it
  const needsChoice = form?.role === 'sales';
  const ready = whoOk && dated && !!car && (!needsChoice || !!choice);
  const price = async () => { setPriced(null); const r = await act('price', () => api.call('sales.offerRead', { body: { what: 'offer_preview', p: payload() } })); if (r.ok) setPriced(r.data as Priced); };
  const send = async () => { const r = await act('send', () => api.call('sales.offer', { body: { action: 'offer_create', p: payload() } })); if (r.ok) setSent(r.data as { booking_number: string; total_cents: number; notified: boolean }); };

  if (sent) {
    return (
      <Screen testID="offer-sent">
        <Notice tone="ok" title="Offer sent">{sent.booking_number} · {money(sent.total_cents)}{sent.notified ? ' · the renter has the link to accept, sign and pay.' : ' · saved; the renter was not notified.'}</Notice>
        <Button label="Done" onPress={() => router.back()} />
        <Button label="Open it on carmacars.ca" variant="ghost" onPress={() => void openSite('/staff/offers', config?.site_url)} />
      </Screen>
    );
  }
  if (!form && busy === 'form') return <Busy label="Loading" />;
  return (
    <Screen testID="offer" footer={priced?.ok !== false && priced?.available ? <Button label={`Send the offer · ${money(priced.booking.renter_due_at_booking_cents ?? priced.booking.total_due_at_booking_cents)}`} onPress={() => void send()} busy={busy === 'send'} testID="send-offer" />
      : <Button label="See the price" onPress={() => void price()} busy={busy === 'price'} disabled={!ready} testID="price" />}>
      <Stack.Screen options={{ title: 'Send an offer' }} />
      {error ? <Notice tone="bad">{error}</Notice> : null}
      <H2 style={{ marginTop: 0 }}>Who</H2>
      {renter ? (
        <Card><Text style={type.h3}>{renter.legal_name}</Text><Small>{[renter.email, renter.mobile].filter(Boolean).join(' · ')}</Small>
          {renter.is_blocked ? <Notice tone="bad">This renter is blocked.</Notice> : null}
          <Button label="Someone else" variant="ghost" onPress={() => { setRenter(null); setPriced(null); }} /></Card>
      ) : (<>
        <Field label="Find a renter (name, email or phone)" value={q} onChangeText={setQ} autoCorrect={false} />
        {found.slice(0, 5).map((f) => <Card key={f.id} onPress={() => { setRenter(f); setPriced(null); }} label={`Choose ${f.legal_name}`}><Text style={type.h3}>{f.legal_name}</Text><Small>{[f.email, f.mobile].filter(Boolean).join(' · ')}</Small></Card>)}
        <Small style={{ marginBottom: space.sm }}>Or someone new:</Small>
        <Field label="Full name" value={fresh.full_name} onChangeText={(v) => setFresh({ ...fresh, full_name: v })} autoCapitalize="words" />
        <Field label="Email" value={fresh.email} onChangeText={(v) => setFresh({ ...fresh, email: v })} keyboardType="email-address" autoCapitalize="none" />
        <Field label="Mobile" value={fresh.mobile} onChangeText={(v) => setFresh({ ...fresh, mobile: v })} keyboardType="phone-pad" />
        <WhenField label="Date of birth" mode="date" value={fresh.date_of_birth} onChange={(v) => setFresh({ ...fresh, date_of_birth: v })} />
      </>)}
      <H2>When</H2>
      <Row style={{ alignItems: 'flex-start' }}><WhenField label="Pickup" mode="date" value={from} min={torontoDay()} onChange={(v) => { setFrom(v); setPriced(null); }} /><WhenField label="Time" mode="time" value={tf} onChange={(v) => { setTf(v); setPriced(null); }} /></Row>
      <Row style={{ alignItems: 'flex-start' }}><WhenField label="Return" mode="date" value={to} min={from || torontoDay()} onChange={(v) => { setTo(v); setPriced(null); }} /><WhenField label="Time" mode="time" value={tt} onChange={(v) => { setTt(v); setPriced(null); }} /></Row>
      <H2>Car</H2>
      {!dated ? <Small>Choose the dates to see which cars are free.</Small> : null}
      <Wrap>{(form?.cars ?? []).filter((c) => !dated || c.free !== false).slice(0, 40).map((c) => <Chip key={c.id} label={`${c.name}${c.daily_rate_cents ? ` · ${money(c.daily_rate_cents)}` : ''}`} on={car === c.id} onPress={() => { setCar(c.id); setPriced(null); }} />)}</Wrap>
      <H2>Coverage</H2>
      <Wrap><Chip label="Protection Plan" on={coverage === '3'} onPress={() => { setCoverage('3'); setPriced(null); }} /><Chip label="Their own policy (OPCF 27)" on={coverage === '1'} onPress={() => { setCoverage('1'); setPriced(null); }} /></Wrap>
      {needsChoice ? (<>
        <H2>Whose client</H2>
        <Wrap><Chip label="I sourced this client" on={choice === 'sourced'} onPress={() => { setChoice('sourced'); setPriced(null); }} testID="choice-sourced" /><Chip label="Entered for CarmaCars" on={choice === 'for_carmacars'} onPress={() => { setChoice('for_carmacars'); setPriced(null); }} /></Wrap>
      </>) : null}
      <H2>Send it</H2>
      <Check label="By text" on={byText} onChange={setByText} />
      <Check label="By email" on={byEmail} onChange={setByEmail} />
      <Field label="Message to the renter (optional)" value={message} onChangeText={setMessage} multiline maxLength={1000} />
      {priced ? (priced.ok === false ? <Notice tone="bad">{priced.error ?? 'This offer cannot be priced.'}</Notice> : (
        <Card testID="priced">
          {!priced.available ? <Notice tone="bad">The car is not free for these dates.</Notice> : null}
          <Pair k={`Rental, ${priced.booking.billable_days} day${priced.booking.billable_days === 1 ? '' : 's'}`} v={money(priced.booking.rental_charge_cents)} />
          <Pair k="Due to confirm" v={money(priced.booking.renter_due_at_booking_cents ?? priced.booking.total_due_at_booking_cents)} strong />
          <Pair k="Deposit" v={money(priced.booking.deposit_cents)} />
        </Card>
      )) : null}
      <View style={{ marginTop: space.md }}><Button label="A custom price, delivery or add-ons: the site's offer page" variant="ghost" onPress={() => void openSite('/staff/offers', config?.site_url)} /></View>
    </Screen>
  );
}
