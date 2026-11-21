import { useCallback, useEffect, useState } from 'react';
import { Text, View } from 'react-native';
import { Stack } from 'expo-router';
import { useApp } from '@/app-state';
import { applyChange, CADENCES, CHANNELS, channelNote, summaryLine, type PrefChange, type PrefState, type PrefType } from '@/shared';
import { Badge, Card, Check, Chip, Failed, Line, Notice, P, Screen, Wrap } from '@/ui/kit';
import { color, space, type } from '@/theme';

// Notification preferences (release 48): the same choices as the website's Notifications page, saved to the same place.
// Each kind by push, email and text; quiet hours; instant or a daily or weekly summary. The kinds marked Always on are
// about security, agreements, money and bookings (for staff, assigned work and access): the site refuses to switch them
// off. A switch moves at once and is put back with the site's words if it is refused.
export default function NotificationPreferences() {
  const { api, me } = useApp();
  const portal = me?.roles.admin ? 'admin' : me?.roles.staff || me?.roles.field ? 'staff' : me?.roles.owner ? 'owner' : me?.roles.investor ? 'investor' : 'renter';
  const [s, setS] = useState<PrefState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    const r = await api.call('me.notifyPrefs', { query: { portal } });
    if (r.ok) setS(r.data as PrefState); else setError(r.message);
    setLoading(false);
  }, [api, portal]);
  useEffect(() => { void load(); }, [load]);

  const send = async (change: PrefChange) => {
    if (!s) return;
    const before = s;
    setS(applyChange(s, change)); setMsg(null);
    const r = await api.call('me.notifyPrefsSave', { body: { portal, ...change } as never });
    if (r.ok) { setS(r.data as PrefState); setMsg({ ok: true, text: 'Saved.' }); } else { setS(before); setMsg({ ok: false, text: r.message }); }
  };
  if (error && !s) return <Screen testID="notify-prefs"><Stack.Screen options={{ title: 'Notifications' }} /><Failed message={error} onRetry={() => void load()} /></Screen>;
  const row = (t: PrefType) => (
    <View key={t.code} style={{ paddingVertical: space.sm }}>
      <Text style={[type.body, { fontWeight: '700' }]}>{t.label}</Text>
      {t.detail ? <Text style={[type.small, { color: color.muted }]}>{t.detail}</Text> : null}
      {!t.live ? <Text style={[type.small, { color: color.muted }]}>Starts when your tracker is installed. Your choice is kept.</Text> : null}
      {t.locked ? <View style={{ marginTop: space.xs }}><Badge label="Always on" tone="muted" /></View>
        : <Wrap style={{ marginTop: space.xs }}>{CHANNELS.filter((c) => t.channels.includes(c.key)).map((c) => (
            <Chip key={c.key} label={`${c.label} ${t[c.key] ? 'on' : 'off'}`} on={t[c.key]} onPress={() => void send({ type: t.code, channel: c.key, on: !t[c.key] })} testID={`np-${t.code}-${c.key}`} />))}</Wrap>}
    </View>
  );
  return (
    <Screen onRefresh={() => void load()} refreshing={loading} testID="notify-prefs">
      <Stack.Screen options={{ title: 'Notifications' }} />
      {s ? (<>
        <P>{summaryLine(s)}</P>
        {msg ? <Notice tone={msg.ok ? 'ok' : 'bad'}>{msg.text}</Notice> : null}
        {CHANNELS.map((c) => ({ c, note: channelNote(s, c.key) })).filter((x) => x.note).map((x) => <Notice key={x.c.key} tone="info" title={x.c.label}>{x.note}</Notice>)}
        <Card>
          <Text style={[type.label, { marginBottom: space.xs }]}>How often</Text>
          <Wrap>{CADENCES.map((c) => <Chip key={c.key} label={c.label} on={s.profile.cadence === c.key} onPress={() => void send({ cadence: c.key })} testID={`np-cadence-${c.key}`} />)}</Wrap>
          <Line />
          <Check label="Quiet hours: optional alerts and texts wait until morning" on={s.profile.quiet_on} onChange={(v) => void send({ quiet_on: v })} testID="np-quiet" />
          <Check label="Turn every optional notification off" on={s.profile.all_off} onChange={(v) => void send({ all_off: v })} testID="np-all-off" />
        </Card>
        {s.groups.map((g) => (
          <Card key={g.name}>
            <Text style={type.label}>{g.locked ? 'Always on' : g.name}</Text>
            {g.locked ? <Text style={[type.small, { color: color.muted }]}>About your security, your agreements, your money and your bookings. They cannot be switched off.</Text> : null}
            {g.types.map(row)}
          </Card>
        ))}
      </>) : <P>Loading your preferences.</P>}
    </Screen>
  );
}
