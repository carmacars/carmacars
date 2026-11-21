import { useCallback, useEffect, useState } from 'react';
import { AppState, Linking, Switch, Text, View } from 'react-native';
import { Stack } from 'expo-router';
import { useApp, useLoad } from '@/app-state';
import { stateLine, type MyLocation } from '@/shared';
import { canSwitchOff, needsPolicy, permissionLine, policyAccepted, policyBody, prefsBody, switchLine, type Perms } from '@/logic/location';
import { ask, perms, sync } from '@/location';
import * as Haptics from 'expo-haptics';
import { color, space, type } from '@/theme';
import { Busy, Button, Card, Failed, Notice, P, Screen, Small } from '@/ui/kit';

// Profile > Location on the live map: the site's settings card (web/src/features/location/LocationCard.tsx) on the phone.
// Whether it is shared now and why, the switch (on by default; staff cannot turn it off during an active job), the
// phone's own permission, and for staff the electronic monitoring policy (Ontario ESA Part XI.1), accepted once.
const when = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: 'long', day: 'numeric' });

export default function LocationSettings() {
  const { api } = useApp();
  const load = useLoad<MyLocation>('me.location', () => api.call('me.location'));
  const [s, setS] = useState<MyLocation | null>(null);
  const [p, setP] = useState<Perms>({ foreground: 'undetermined', background: 'undetermined' });
  const [busy, setBusy] = useState<'' | 'policy' | 'switch' | 'allow'>('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => { if (load.data) setS(load.data); }, [load.data]);
  const readPerms = useCallback(() => { void perms().then(setP); }, []);
  // the person may come back from the phone's settings with another answer
  useEffect(() => { readPerms(); const sub = AppState.addEventListener('change', (st) => { if (st === 'active') readPerms(); }); return () => sub.remove(); }, [readPerms]);

  if (!s) return load.error ? <Screen><Failed message={load.error} onRetry={load.reload} /></Screen> : <Screen><Busy /></Screen>;
  if (!s.kind) return <Screen testID="location"><Stack.Screen options={{ title: 'Location on the live map' }} /><P>Nothing is shared from this account.</P></Screen>;
  const staff = s.kind === 'staff';
  const on = s.sharing_on !== false;
  const offLocked = on && !canSwitchOff(s);

  const run = async (what: 'policy' | 'switch', body: ReturnType<typeof prefsBody>, ok: string) => {
    setBusy(what); setMsg(null);
    const r = await api.call('me.locationAct', { body });
    setBusy('');
    if (!r.ok) { setMsg({ ok: false, text: r.message }); void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error).catch(() => undefined); return; }
    const next = { ...s, ...r.data };
    setS(next); setMsg({ ok: true, text: ok }); void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined);
    // accepted, or turned back on: the phone's question now, then start (or stop) at once
    if ((what === 'policy' || (what === 'switch' && body.sharing_on === true)) && p.foreground === 'undetermined') setP(await ask(next));
    const fresh = await sync();
    if (fresh) setS(fresh);
  };
  const allow = async () => {
    setBusy('allow'); setMsg(null);
    const got = await ask(s);
    setP(got); setBusy('');
    if (got.foreground === 'granted') { setMsg({ ok: true, text: 'Allowed on this phone.' }); void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => undefined); const fresh = await sync(); if (fresh) setS(fresh); }
    else setMsg({ ok: false, text: 'Location is off for CarmaCars. Turn it on in the phone\'s settings, then come back.' });
  };
  const permLine = permissionLine(s, p);

  return (
    <Screen onRefresh={() => { load.reload(); readPerms(); }} refreshing={load.refreshing} testID="location">
      <Stack.Screen options={{ title: 'Location on the live map' }} />
      <Card>
        <Text accessibilityRole="text" accessibilityLiveRegion="polite" style={[type.body, { marginBottom: space.sm }]} testID="location-state">{stateLine(s)}</Text>
        {staff && needsPolicy(s) ? (
          <View testID="location-policy">
            <Notice tone="info" title="Electronic monitoring policy">{s.policy!.text}</Notice>
            <Button label="I have read it and accept" busy={busy === 'policy'} disabled={!!busy && busy !== 'policy'} testID="location-accept"
              onPress={() => void run('policy', policyBody(s.policy!.version), 'Accepted. Your copy of the policy is on its way by email.')} />
          </View>
        ) : null}
        {staff && policyAccepted(s) ? <Small>Electronic monitoring policy accepted on {when(s.policy!.accepted_at!)}. Your copy was emailed to you and is always sent (it cannot be turned off).</Small> : null}
      </Card>

      <Card>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: space.md }}>
          <View style={{ flex: 1 }}>
            <Text style={type.h3}>Share my location</Text>
            <Small>{switchLine(s)}</Small>
          </View>
          <Switch value={on} disabled={!!busy || offLocked} testID="location-switch" accessibilityLabel="Share my location"
            trackColor={{ false: color.line, true: color.red }} thumbColor={color.white} ios_backgroundColor={color.line}
            onValueChange={(v) => void run('switch', prefsBody(v), v ? 'On.' : 'Off. Nothing is shared.')} />
        </View>
        {permLine ? (
          <View style={{ marginTop: space.md }}>
            <Small>{permLine}</Small>
            {p.foreground === 'denied' || (p.foreground === 'granted' && p.background === 'denied')
              ? <Button label="Open the phone's settings" variant="outline" onPress={() => void Linking.openSettings()} testID="location-settings" />
              : <Button label={p.foreground === 'granted' ? 'Allow with the app closed' : 'Allow on this phone'} variant="outline" busy={busy === 'allow'} disabled={!!busy && busy !== 'allow'}
                  onPress={() => void allow()} testID="location-allow" />}
          </View>
        ) : null}
      </Card>
      {msg ? <Notice tone={msg.ok ? 'ok' : 'bad'}>{msg.text}</Notice> : null}
      <Small>We keep only where you are now, plus the points of each job, pickup or return for 30 days. No history.</Small>
    </Screen>
  );
}
