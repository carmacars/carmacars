import { useEffect, useState } from 'react';
import { Stack } from 'expo-router';
import { useApp } from '@/app-state';
import { TOPICS } from '@/shared';
import { Button, Check, Notice, P, Screen } from '@/ui/kit';

// What alerts this account: the site's nine topics. The site decides which notices belong to which topic.
const WORDS: Record<string, string> = { requests: 'Requests and offers', bookings: 'Booking changes', payments: 'Payments', handovers: 'Pickups and returns', messages: 'Messages', alerts: 'Urgent alerts',
  documents: 'Documents and statements', leads: 'New leads', visitors: 'Hot visitors' };
const STAFF_ONLY = new Set(['leads', 'visitors']);

export default function Alerts() {
  const { api, me, reloadMe } = useApp();
  const [topics, setTopics] = useState<string[]>(me?.push?.topics ?? []);
  const [state, setState] = useState<'idle' | 'saving' | 'saved' | string>('idle');
  useEffect(() => { if (me?.push) setTopics(me.push.topics); }, [me?.push]);
  const staff = !!(me?.roles.staff || me?.roles.admin || me?.roles.field);
  const save = async () => {
    setState('saving');
    const r = await api.call('me.pushTopics', { body: { topics: topics.filter((t): t is (typeof TOPICS)[number] => (TOPICS as readonly string[]).includes(t)) } });
    setState(r.ok ? 'saved' : r.message);
    if (r.ok) void reloadMe();
  };
  return (
    <Screen footer={<Button label="Save" onPress={() => void save()} busy={state === 'saving'} />} testID="alerts">
      <Stack.Screen options={{ title: 'Alerts' }} />
      <P>Choose what sends an alert to your phones.</P>
      {state === 'saved' ? <Notice tone="ok">Saved.</Notice> : state !== 'idle' && state !== 'saving' ? <Notice tone="bad">{state}</Notice> : null}
      {TOPICS.filter((t) => staff || !STAFF_ONLY.has(t)).map((t) => (
        <Check key={t} label={WORDS[t] ?? t} on={topics.includes(t)} onChange={(v) => { setState('idle'); setTopics((p) => (v ? [...new Set([...p, t])] : p.filter((x) => x !== t))); }} />
      ))}
    </Screen>
  );
}
