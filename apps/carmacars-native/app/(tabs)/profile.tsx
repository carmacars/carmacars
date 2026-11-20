import { useEffect, useState } from 'react';
import { Alert, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { useApp } from '@/app-state';
import { APP_VERSION, openSite } from '@/native';
import { heldMessage, portalPath } from '@/logic/roles';
import { disablePush, enablePush, pushIsOn } from '@/push';
import { space, type } from '@/theme';
import { Button, Card, Check, H2, Line, Notice, Pair, Screen, Small } from '@/ui/kit';

// Profile: the account, alerts on this phone, the app lock, passkeys, deleting the account, and the rest of the site.
export default function Profile() {
  const { api, me, session, signOut, lockEnabled, lockAvailable, setLockEnabled, config, portal, reloadMe } = useApp();
  const router = useRouter();
  const [push, setPush] = useState(false);
  const [msg, setMsg] = useState<{ tone: 'ok' | 'bad'; text: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => { void pushIsOn().then(setPush); }, [session]);
  const site = (path: string) => void openSite(path, config?.site_url);

  if (!session) {
    return (
      <Screen testID="profile">
        <Text style={type.h1}>Welcome</Text>
        <Text style={[type.body, { marginBottom: space.lg }]}>Sign in to book a car, sign your agreement, pay, check in and follow your trip.</Text>
        <Button label="Sign in" onPress={() => router.push('/sign-in')} testID="go-sign-in" />
        <Line />
        <Button label="How it works" variant="ghost" onPress={() => site('/how-it-works')} />
        <Button label="Privacy" variant="ghost" onPress={() => site('/privacy')} />
        <Button label="Terms" variant="ghost" onPress={() => site('/terms')} />
        <Small style={{ textAlign: 'center' }}>CarmaCars {APP_VERSION}</Small>
      </Screen>
    );
  }
  const togglePush = async (on: boolean) => {
    setBusy('push'); setMsg(null);
    if (on) { const r = await enablePush(api, portal); if (r.ok) setPush(true); else setMsg({ tone: 'bad', text: r.message }); }
    else { await disablePush(api); setPush(false); }
    setBusy(null);
  };
  const test = async () => { setBusy('test'); const r = await api.call('me.pushTest'); setBusy(null); setMsg(r.ok ? { tone: 'ok', text: 'A test alert is on its way to your devices.' } : { tone: 'bad', text: r.message }); };
  const toggleLock = async (on: boolean) => { if (!(await setLockEnabled(on))) setMsg({ tone: 'bad', text: 'The app lock was not changed.' }); };
  const out = () => Alert.alert('Sign out?', 'This phone forgets your session. Your account and bookings stay as they are.', [{ text: 'Cancel', style: 'cancel' }, { text: 'Sign out', style: 'destructive', onPress: () => { void signOut().then(() => router.replace('/')); } }]);
  const held = heldMessage(me?.roles ?? null);
  const portalHome = portalPath(me?.roles ?? null);

  return (
    <Screen onRefresh={() => void reloadMe()} testID="profile">
      <Text style={type.h1}>{me?.roles.greeting ?? me?.roles.name ?? 'Your account'}</Text>
      {msg ? <Notice tone={msg.tone}>{msg.text}</Notice> : null}
      {me?.needs_two_step ? <Notice tone="warn" title="Two-step sign-in needed"><Button label="Enter the code" onPress={() => router.push('/two-step')} /></Notice> : null}
      {held ? <Notice tone="warn">{held}</Notice> : null}
      <Card>
        {me?.user.email ? <Pair k="Email" v={me.user.email} /> : null}
        {me?.user.phone ? <Pair k="Mobile" v={me.user.phone} /> : null}
        <Button label="Edit my details on carmacars.ca" variant="ghost" onPress={() => site('/account/profile')} />
      </Card>

      <H2>This phone</H2>
      <Card>
        {me?.push_available ? (<>
          <Check label="Alerts on this phone" on={push} onChange={(v) => void togglePush(v)} testID="push-toggle" />
          <Small>Offers, payments, pickups and messages, as they happen.</Small>
          {push ? <View style={{ marginTop: space.sm }}><Button label="Send a test alert" variant="outline" onPress={() => void test()} busy={busy === 'test'} /><Button label="Choose what alerts me" variant="ghost" onPress={() => router.push('/settings/alerts' as never)} /></View> : null}
          <Line />
        </>) : null}
        {lockAvailable ? (<>
          <Check label="App lock" on={lockEnabled} onChange={(v) => void toggleLock(v)} testID="lock-toggle" />
          <Small>Face ID, fingerprint or your passcode opens CarmaCars after 5 minutes away.</Small>
        </>) : <Small>Set up Face ID, a fingerprint or a passcode on this phone to lock the app.</Small>}
        <Line />
        <Button label="Passkeys" variant="outline" onPress={() => router.push('/settings/passkeys' as never)} testID="passkeys" />
      </Card>

      {portalHome ? (<>
        <H2>{me?.roles.admin ? 'Admin' : 'More of your work'}</H2>
        <Card>
          <Small style={{ marginBottom: space.sm }}>{me?.roles.admin ? 'The Admin portal opens in the browser inside the app, signed in on carmacars.ca.' : 'Pages the app does not have open on carmacars.ca, inside the app.'}</Small>
          <Button label={me?.roles.admin ? 'Open the Admin portal' : 'Open my portal'} variant="dark" onPress={() => site(portalHome)} testID="open-portal" />
        </Card>
      </>) : null}

      <H2>Help and legal</H2>
      <Button label="Contact us" variant="outline" onPress={() => site('/contact')} />
      <Button label="Privacy" variant="ghost" onPress={() => site('/privacy')} />
      <Button label="Terms" variant="ghost" onPress={() => site('/terms')} />
      <Line />
      <Button label="Sign out" variant="outline" onPress={out} testID="sign-out" />
      <Button label="Delete my account" variant="danger" onPress={() => router.push('/settings/delete-account' as never)} testID="delete-account" />
      <Small style={{ textAlign: 'center', marginTop: space.md }}>CarmaCars {APP_VERSION} · 18122211 Canada Inc.</Small>
    </Screen>
  );
}
