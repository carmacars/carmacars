import { useEffect, useState } from 'react';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { initPaymentSheet, initStripe, presentPaymentSheet } from '@stripe/stripe-react-native';
import { forgetLoaded, useApp, useLoad } from '@/app-state';
import type { StartedPayment } from '@/shared';
import { money } from '@/logic/format';
import { openSite } from '@/native';
import { Busy, Button, H1, Notice, P, Screen, Small } from '@/ui/kit';

// Paying for the booking with Stripe's own payment sheet (the card never touches the app or the site). The site makes
// the payment for the amount the database says is due and, once Stripe has it, settles the booking with the same step
// the website's pay page runs.
export default function Pay() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api, config } = useApp();
  const router = useRouter();
  const start = useLoad<StartedPayment>(`pay:${number}`, () => api.call('trip.payStart', { params: { number } }));
  const [state, setState] = useState<'idle' | 'paying' | 'settling' | 'done'>('idle');
  const [error, setError] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const p = start.data;

  useEffect(() => {
    if (!p || p.provider !== 'stripe' || !p.publishableKey) return;
    let live = true;
    void (async () => {
      await initStripe({ publishableKey: p.publishableKey!, urlScheme: 'carmacars' });
      const r = await initPaymentSheet({ paymentIntentClientSecret: p.clientSecret, merchantDisplayName: 'CarmaCars', returnURL: 'carmacars://stripe-redirect', allowsDelayedPaymentMethods: false,
        defaultBillingDetails: { name: p.legalName }, appearance: { colors: { primary: '#D0111B' } } });
      if (!live) return;
      if (r.error) setError(r.error.message); else setReady(true);
    })();
    return () => { live = false; };
  }, [p]);

  const settle = async () => {
    setState('settling');
    const r = await api.call('trip.payFinish', { params: { number }, body: { intentId: p!.intentId } });
    const d = r.ok ? (r.data as { ok: boolean; message?: string }) : null;
    if (r.ok && d?.ok) { forgetLoaded('trip'); forgetLoaded('pay'); setState('done'); return; }
    setState('idle');
    setError(r.ok ? d?.message ?? 'The payment was not confirmed.' : r.message);
  };
  const pay = async () => {
    setError(null); setState('paying');
    const r = await presentPaymentSheet();
    if (r.error) { setState('idle'); if (r.error.code !== 'Canceled') setError(r.error.message); return; }
    await settle();
  };

  if (start.loading) return <Busy label="Preparing your payment" />;
  if (state === 'done') {
    return (
      <Screen testID="paid">
        <Notice tone="ok" title="You are booked">Your payment went through and your booking is confirmed. The receipt is in your email.</Notice>
        <Button label="Open my trip" onPress={() => router.replace(`/trip/${number}` as never)} testID="open-trip" />
      </Screen>
    );
  }
  if (!p) {
    // the server's own reason: sign first, add the licence first, already confirmed, nothing due
    const code = start.code;
    return (
      <Screen testID="pay-blocked">
        <Stack.Screen options={{ title: 'Pay' }} />
        <Notice tone={code === 'confirmed' ? 'ok' : 'warn'}>{start.error ?? 'Nothing to pay right now.'}</Notice>
        {code === 'unsigned' ? <Button label="Sign the agreement" onPress={() => router.replace(`/trip/${number}/sign` as never)} /> : null}
        {code === 'licence' || code === 'coverage' ? <Button label="Add your licence and selfie" onPress={() => router.replace(`/trip/${number}/verify` as never)} /> : null}
        {code === 'email_needed' ? <Button label="Add your email on carmacars.ca" onPress={() => void openSite(`/account/bookings/${number}/checkout`, config?.site_url)} /> : null}
        <Button label="Back to my trip" variant="outline" onPress={() => router.replace(`/trip/${number}` as never)} />
        <Button label="Try again" variant="ghost" onPress={start.reload} />
      </Screen>
    );
  }
  return (
    <Screen testID="pay">
      <Stack.Screen options={{ title: 'Pay' }} />
      <H1>{money(p.amountCents)}</H1>
      <P>Due now to confirm booking {number}. The refundable deposit is held on your card and released after the return.</P>
      {p.coverageNetwork ? <Notice tone="warn">Pay with your {p.coverageNetwork.label} credit card: it is the card whose rental coverage you chose.</Notice> : null}
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {p.provider !== 'stripe' || !p.publishableKey ? <Notice tone="warn">Card payments are not set up on this server. Pay on carmacars.ca.</Notice>
        : <Button label={state === 'settling' ? 'Confirming…' : `Pay ${money(p.amountCents)}`} onPress={() => void pay()} busy={state !== 'idle'} disabled={!ready} testID="pay-now" />}
      <Button label="Pay on carmacars.ca instead" variant="ghost" onPress={() => void openSite(`/account/bookings/${number}/checkout#pay`, config?.site_url)} />
      <Small>Payments are processed by Stripe. CarmaCars never sees your full card number.</Small>
    </Screen>
  );
}
