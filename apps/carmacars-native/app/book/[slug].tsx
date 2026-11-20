import { useEffect, useMemo, useRef, useState } from 'react';
import { Text, View } from 'react-native';
import * as Crypto from 'expo-crypto';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useApp, useLoad } from '@/app-state';
import { emptyForm, requestData, requestKey, stepErrors, type Errors, type Form } from '@/logic/booking';
import { money, torontoDay, when } from '@/logic/format';
import { openSite } from '@/native';
import { space, type } from '@/theme';
import { Busy, Button, Check, Chip, Field, H2, Notice, P, Row, Screen, Small, Wrap } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';
import { BOT_CHECK_FAILED, useBotCheck } from '@/ui/shell';

// Request to book, in three short steps: when and where, who drives, the licence and the coverage. What is sent is the
// site's own request; the site's schema and the database check it again and answer with the same messages.
interface Account { signedIn: boolean; email: string | null; phone: string | null; canBookNow: boolean; profile: { first?: string; last?: string; full_name?: string; date_of_birth?: string | null; licence_class?: string | null } | null }
const nowMinutes = () => { const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date()); return Number(p.find((x) => x.type === 'hour')!.value) % 24 * 60 + Number(p.find((x) => x.type === 'minute')!.value); };

export default function Book() {
  const p = useLocalSearchParams<{ slug: string; from?: string; to?: string }>();
  const { api, config, session } = useApp();
  const router = useRouter();
  const bot = useBotCheck();
  const car = useLoad(`car:${p.slug}`, () => api.call('car', { params: { slug: p.slug } }));
  const account = useLoad<{ signedIn: boolean } & Account>(session ? 'request.account' : null, () => api.call('request.account') as Promise<{ ok: true; data: Account } | { ok: false; code: string; message: string }>);
  const [f, setF] = useState<Form>(() => emptyForm(p.slug, p.from ?? '', p.to ?? ''));
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [errors, setErrors] = useState<Errors>({});
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState<string | null>(null);
  const [sent, setSent] = useState<{ bookingNumber: string; totalCents: number | null; instant?: boolean } | null>(null);
  const key = useRef(requestKey(Crypto.randomUUID()));
  const set = (patch: Partial<Form>) => { setF((x) => ({ ...x, ...patch })); setErrors({}); };
  const rules = config?.rules ?? { min_age: 21, max_days: 30, notice_minutes: 120, licence_classes: ['G', 'G2'] };
  const insuranceIncluded = !!(car.data?.car as { insurance_included?: boolean } | undefined)?.insurance_included;
  const ctx = useMemo(() => ({ todayIso: torontoDay(), nowMinutes: nowMinutes(), signedInWithoutEmail: !!session && !session.user.email, insuranceIncluded }), [session, insuranceIncluded, step]); // eslint-disable-line react-hooks/exhaustive-deps

  // what the account already knows fills the form once
  useEffect(() => {
    const a = account.data;
    if (!a) return;
    const [first = '', ...rest] = (a.profile?.full_name ?? '').split(' ');
    const dob = (a.profile?.date_of_birth ?? '').split('-');
    setF((x) => ({ ...x, email: x.email || a.email || '', phone: x.phone || a.phone || '', first: x.first || a.profile?.first || first, last: x.last || a.profile?.last || rest.join(' '),
      dobY: x.dobY || dob[0] || '', dobM: x.dobM || String(Number(dob[1] ?? '') || ''), dobD: x.dobD || String(Number(dob[2] ?? '') || ''), licClass: x.licClass || a.profile?.licence_class || '' }));
  }, [account.data]);

  if (!session) return <Screen><Notice title="Sign in to book">Your request, your offer and your trip stay with your account.</Notice><Button label="Sign in" onPress={() => router.push('/sign-in')} /></Screen>;
  if (car.loading) return <Busy />;
  const name = car.data ? `${(car.data.car as { year?: number | null }).year ?? ''} ${car.data.car.make} ${car.data.car.model}`.trim() : 'this car';

  const next = () => {
    const e = stepErrors(step, f, rules, ctx);
    setErrors(e);
    if (Object.keys(e).length) return;
    if (step < 3) setStep((step + 1) as 2 | 3); else void send();
  };
  const send = async () => {
    setBusy(true); setFailed(null);
    const token = await bot.ask();
    if (token === null) { setBusy(false); setFailed(BOT_CHECK_FAILED); return; }
    const r = await api.call('request.submit', { body: { data: requestData(f), requestKey: key.current, turnstile: token || undefined, bookNow: undefined } });
    setBusy(false);
    if (r.ok) { forgetLoaded('trips'); setSent(r.data as { bookingNumber: string; totalCents: number | null; instant?: boolean }); return; }
    setFailed(r.message);
    // the site names the field: go to the step that has it
    const fe = r.fieldErrors ?? {};
    setErrors(fe as Errors);
    if (['from', 'to', 'tf', 'tt', 'pickupAt', 'pickupAirport', 'returnAt', 'returnAirport', 'dates'].some((k) => k in fe)) setStep(1);
    else if (['first', 'last', 'email', 'phone', 'dob'].some((k) => k in fe)) setStep(2);
  };

  if (sent) {
    return (
      <Screen testID="request-sent">
        <Notice tone="ok" title={sent.instant ? 'Booked: sign and pay to confirm' : 'Request sent'}>
          {sent.instant ? 'Your booking is ready for your signature and payment.' : 'We check the car and send your offer, usually within the hour during the day. You get an alert when it is ready.'}
        </Notice>
        <P>Reference {sent.bookingNumber}{sent.totalCents ? ` · estimated ${money(sent.totalCents)}` : ''}</P>
        <Button label="Open my trip" onPress={() => router.replace(`/trip/${sent.bookingNumber}` as never)} testID="open-trip" />
      </Screen>
    );
  }
  const where = (kind: 'pickupAt' | 'returnAt', airport: 'pickupAirport' | 'returnAirport') => (
    <View style={{ marginBottom: space.md }}>
      <Wrap>
        <Chip label="Our location" on={f[kind] === 'ours'} onPress={() => set({ [kind]: 'ours' } as Partial<Form>)} />
        {car.data?.places?.owner_location ? <Chip label={`The car's home${car.data.places.area ? ` (${car.data.places.area})` : ''}`} on={f[kind] === 'owner'} onPress={() => set({ [kind]: 'owner' } as Partial<Form>)} /> : null}
        {(config?.airports ?? []).length ? <Chip label="Airport" on={f[kind] === 'airport'} onPress={() => set({ [kind]: 'airport', [airport]: f[airport] || config!.airports[0]!.code } as Partial<Form>)} /> : null}
      </Wrap>
      {f[kind] === 'airport' ? <Wrap style={{ marginTop: space.sm }}>{config!.airports.map((a) => <Chip key={a.code} label={a.name} on={f[airport] === a.code} onPress={() => set({ [airport]: a.code } as Partial<Form>)} />)}</Wrap> : null}
      {errors[airport] ? <Small style={{ color: '#D0111B' }}>{errors[airport]}</Small> : null}
    </View>
  );

  return (
    <Screen testID="book" footer={<><Button label={step < 3 ? 'Continue' : 'Send request'} onPress={next} busy={busy} testID="next" />{step > 1 ? <Button label="Back" variant="ghost" onPress={() => setStep((step - 1) as 1 | 2)} /> : null}</>}>
      <Stack.Screen options={{ title: 'Request to book' }} />
      {bot.sheet}
      <Small>Step {step} of 3 · {name}</Small>
      {failed ? <Notice tone="bad">{failed}</Notice> : null}
      {step === 1 ? (<>
        <H2 style={{ marginTop: space.sm }}>When</H2>
        <Row style={{ alignItems: 'flex-start' }}>
          <WhenField label="Pickup date" mode="date" value={f.from} min={ctx.todayIso} onChange={(v) => set({ from: v, to: f.to && f.to < v ? '' : f.to })} error={errors.from} />
          <WhenField label="Time" mode="time" value={f.tf} onChange={(v) => set({ tf: v })} error={errors.tf} />
        </Row>
        <Row style={{ alignItems: 'flex-start' }}>
          <WhenField label="Return date" mode="date" value={f.to} min={f.from || ctx.todayIso} onChange={(v) => set({ to: v })} error={errors.to} />
          <WhenField label="Time" mode="time" value={f.tt} onChange={(v) => set({ tt: v })} error={errors.tt} />
        </Row>
        <Small style={{ marginBottom: space.md }}>Times are Toronto time.</Small>
        <H2>Pickup</H2>{where('pickupAt', 'pickupAirport')}
        <H2>Return</H2>{where('returnAt', 'returnAirport')}
        <Small>Want the car delivered to an address? Ask on carmacars.ca, or tell us in the note at the last step.</Small>
      </>) : step === 2 ? (<>
        <H2 style={{ marginTop: space.sm }}>The driver</H2>
        <Field label="First name, as on your licence" value={f.first} onChangeText={(v) => set({ first: v })} error={errors.first} autoCapitalize="words" autoComplete="given-name" textContentType="givenName" />
        <Field label="Last name" value={f.last} onChangeText={(v) => set({ last: v })} error={errors.last} autoCapitalize="words" autoComplete="family-name" textContentType="familyName" />
        {!ctx.signedInWithoutEmail || f.email ? <Field label="Email" value={f.email} onChangeText={(v) => set({ email: v })} error={errors.email} keyboardType="email-address" autoCapitalize="none" autoComplete="email" /> : null}
        <Field label="Mobile" value={f.phone} onChangeText={(v) => set({ phone: v })} error={errors.phone} keyboardType="phone-pad" autoComplete="tel" />
        <Text style={[type.label, { marginBottom: space.xs }]}>Date of birth</Text>
        <Row style={{ alignItems: 'flex-start' }}>
          <View style={{ flex: 1.3 }}><Field label="Year" value={f.dobY} onChangeText={(v) => set({ dobY: v.replace(/\D/g, '').slice(0, 4) })} keyboardType="number-pad" placeholder="1990" /></View>
          <View style={{ flex: 1 }}><Field label="Month" value={f.dobM} onChangeText={(v) => set({ dobM: v.replace(/\D/g, '').slice(0, 2) })} keyboardType="number-pad" placeholder="5" /></View>
          <View style={{ flex: 1 }}><Field label="Day" value={f.dobD} onChangeText={(v) => set({ dobD: v.replace(/\D/g, '').slice(0, 2) })} keyboardType="number-pad" placeholder="5" /></View>
        </Row>
        {errors.dob ? <Notice tone="bad">{errors.dob}</Notice> : null}
        <Small>Another driver? Add them on carmacars.ca after you send this, or tell us in the note.</Small>
      </>) : (<>
        <H2 style={{ marginTop: space.sm }}>Your licence</H2>
        <Wrap>{rules.licence_classes.map((c) => <Chip key={c} label={`Ontario ${c}`} on={f.licClass === c} onPress={() => set({ licClass: c })} />)}</Wrap>
        {errors.licClass ? <Small style={{ color: '#D0111B', marginTop: space.xs }}>{errors.licClass}</Small> : null}
        <Small style={{ marginTop: space.xs }}>A licence from somewhere else? Send the request on carmacars.ca.</Small>
        {!insuranceIncluded ? (<>
          <H2>How the car is covered</H2>
          <Check label="The CarmaCars Protection Plan (priced in your offer)" on={f.coverage === '3'} onChange={() => set({ coverage: '3', opcfAck: false })} />
          <Check label="My own auto policy with the OPCF 27 endorsement" on={f.coverage === '1'} onChange={() => set({ coverage: '1' })} />
          {f.coverage === '1' ? <Check label="I will upload my policy showing OPCF 27 before pickup" on={f.opcfAck} onChange={(v) => set({ opcfAck: v })} error={errors.opcfAck} /> : null}
          {errors.coverage ? <Small style={{ color: '#D0111B' }}>{errors.coverage}</Small> : null}
          <Button label="Using a credit card's coverage? Book on carmacars.ca" variant="ghost" onPress={() => void openSite(`/book?car=${encodeURIComponent(f.car)}`, config?.site_url)} />
        </>) : <Notice tone="ok">Insurance is included with this car.</Notice>}
        <H2>Anything else?</H2>
        <Field label="Note (optional)" value={f.notes} onChangeText={(v) => set({ notes: v })} error={errors.notes} multiline maxLength={1000} />
        <Field label="Promo code (optional)" value={f.promo} onChangeText={(v) => set({ promo: v })} error={errors.promo} autoCapitalize="characters" autoCorrect={false} />
        <Small style={{ marginBottom: space.sm }}>{when(`${f.from}T12:00:00Z`, false)} to {when(`${f.to}T12:00:00Z`, false)}</Small>
        <Check label="I agree to the rental terms and the privacy policy, and to be contacted about this request." on={f.agree} onChange={(v) => set({ agree: v })} error={errors.agree} testID="agree" />
        <Row><Button label="Terms" variant="ghost" onPress={() => void openSite('/terms', config?.site_url)} /><Button label="Privacy" variant="ghost" onPress={() => void openSite('/privacy', config?.site_url)} /></Row>
        <Check label="Send me CarmaCars offers by email (optional)" on={f.marketing} onChange={(v) => set({ marketing: v })} />
      </>)}
    </Screen>
  );
}
