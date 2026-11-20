import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { locate } from '@/native';
import { clock } from '@/logic/format';
import { clockProblem, elapsed } from '@/logic/field';
import { heldMessage } from '@/logic/roles';
import { color, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Empty, Failed, Field, H2, Notice, Row, Screen, Small } from '@/ui/kit';

// Today for field staff: the shift, clocking in and out with the phone's location, and the day's jobs in order.
interface Card { type: string; key: string; must: boolean; done: boolean; id?: string; kind?: string; leg?: 'pickup' | 'return' | null; status?: string; at?: string; place?: string | null;
  vehicle: { id: string; name: string; plate: string | null }; booking?: { number: string; renter: string | null } | null; blockers?: Array<{ code: string; label: string }> }
interface Today { day: string; on_shift: boolean; shift: { id: string; starts_at: string; ends_at: string; note: string | null } | null; clock: { id: string; started_at: string } | null; cards: Card[];
  counts: { must: number; done: number }; mates?: Array<{ id: string; at: string; kind: string; vehicle: string; booking: string | null }> }
const TITLE: Record<string, string> = { pickup: 'Hand over', return: 'Take back', prep: 'Onboarding prep', clean: 'Clean check', service: 'Service', photos: 'Photos' };

export default function FieldToday() {
  const { api, me } = useApp();
  const router = useRouter();
  const today = useLoad<Today>('field.today', () => api.call('field.today') as Promise<{ ok: true; data: Today } | { ok: false; code: string; message: string }>);
  const { busy, error, act, setError } = useAct();
  const [reason, setReason] = useState('');
  const [askReason, setAskReason] = useState(false);
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 30_000); return () => clearInterval(t); }, []);

  const held = heldMessage(me?.roles ?? null);
  if (held) return <Screen><Notice tone="warn" title="Not open yet">{held}</Notice></Screen>;
  if (today.loading) return <Busy label="Loading today" />;
  if (!today.data) return <Failed message={today.error ?? 'Today could not be loaded.'} onRetry={today.reload} />;
  const t = today.data;

  const punch = async (what: 'in' | 'out') => {
    setError(null);
    const fix = await locate();
    const problem = clockProblem(fix, reason);
    if (problem) { setAskReason(true); setError(problem); return; }
    const r = await act('clock', () => api.call('field.clock', { body: { what, note: undefined, loc: fix ?? undefined, reason: reason.trim() || undefined, openReasons: undefined } }));
    if (r.ok) { setAskReason(false); setReason(''); forgetLoaded('field.'); today.reload(); }
    // away from the lot, or jobs still open: the database asks for the reason in its own words; the field opens for it
    else if (/why|reason/i.test(r.message)) setAskReason(true);
  };
  const take = async (job: string) => { const r = await act(`take-${job}`, () => api.call('field.act', { body: { action: 'job_take', p: { job } } })); if (r.ok) today.reload(); };

  return (
    <Screen onRefresh={today.reload} refreshing={today.refreshing} testID="field-today">
      {error ? <Notice tone="bad">{error}</Notice> : null}
      <Card>
        <Row style={{ justifyContent: 'space-between' }}>
          <View style={{ flex: 1 }}>
            <Text style={type.h3}>{t.clock ? `Clocked in ${elapsed(t.clock.started_at)}` : t.shift ? 'Your shift' : 'No shift today'}</Text>
            <Small>{t.shift ? `${clock(t.shift.starts_at)} to ${clock(t.shift.ends_at)}${t.shift.note ? ` · ${t.shift.note}` : ''}` : 'Claim an open shift to get jobs.'}</Small>
          </View>
          {t.clock ? <Badge label="On the clock" tone="red" /> : null}
        </Row>
        {askReason ? <Field label="The reason" value={reason} onChangeText={setReason} help="An Admin sees this with your hours. Then press the button again." testID="clock-reason" /> : null}
        <View style={{ marginTop: space.md }}>
          {t.clock ? <Button label="Clock out" variant="dark" onPress={() => void punch('out')} busy={busy === 'clock'} testID="clock-out" />
            : <Button label="Clock in" onPress={() => void punch('in')} busy={busy === 'clock'} testID="clock-in" hint="Records the time and where this phone is" />}
          <Button label="My shifts and open shifts" variant="outline" onPress={() => router.push('/field/shifts' as never)} />
        </View>
      </Card>

      <H2>{t.counts.must ? `${t.counts.done} of ${t.counts.must} done` : 'Today'}</H2>
      {!t.cards.length ? <Empty title="No pickups or returns today" body="New jobs show here and arrive as alerts." /> : null}
      {t.cards.map((c) => (
        <Card key={c.key} onPress={c.type === 'job' && c.id ? () => router.push(`/field/job/${c.id}` as never) : undefined} label={`${TITLE[c.leg ?? c.type] ?? 'Job'} ${c.vehicle.name}`} testID={`card-${c.key}`}>
          <Row style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <View style={{ flex: 1 }}>
              <Text style={type.h3}>{c.at ? `${clock(c.at)} · ` : ''}{TITLE[c.leg ?? c.type] ?? c.kind ?? 'Job'}</Text>
              <Text style={type.body}>{c.vehicle.name}{c.vehicle.plate ? ` · ${c.vehicle.plate}` : ''}</Text>
              <Small>{[c.booking?.number, c.booking?.renter, c.place].filter(Boolean).join(' · ')}</Small>
            </View>
            <Badge label={c.done ? 'Done' : c.must ? 'To do' : 'Optional'} tone={c.done ? 'ok' : c.must ? 'red' : 'muted'} />
          </Row>
          {(c.blockers ?? []).map((b) => <Small key={b.code} style={{ color: color.red, marginTop: space.xs }}>{b.label}</Small>)}
          {c.type !== 'job' ? <Small style={{ marginTop: space.xs }}>Open carmacars.ca for this step.</Small> : null}
        </Card>
      ))}
      {(t.mates ?? []).length ? <H2>On your shift, with a teammate</H2> : null}
      {(t.mates ?? []).map((m) => (
        <Card key={m.id}>
          <Text style={type.body}>{clock(m.at)} · {m.vehicle}{m.booking ? ` · ${m.booking}` : ''}</Text>
          <Button label="Take this job" variant="outline" onPress={() => void take(m.id)} busy={busy === `take-${m.id}`} />
        </Card>
      ))}
    </Screen>
  );
}
