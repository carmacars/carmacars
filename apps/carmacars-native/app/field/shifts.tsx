import { Text, View } from 'react-native';
import { Stack } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { clock, when } from '@/logic/format';
import { openSite } from '@/native';
import { type } from '@/theme';
import { Busy, Button, Card, Empty, Failed, H2, Notice, Row, Screen, Small } from '@/ui/kit';

// My shifts, and the open shifts to claim. The database holds the rules (who may take which shift, how late one can be
// given up) and answers a claim it refuses with the reason.
type Slot = { id: string; starts_at: string; ends_at: string; note: string | null; standing?: boolean };
interface Shifts { locked: boolean; mine: Slot[]; open: Array<Slot & { capacity: number; taken: number; mine: boolean }>; offers: Array<{ id: string; starts_at: string; ends_at: string; from: string }>; late_cancels: number }
const span = (s: { starts_at: string; ends_at: string }) => `${when(s.starts_at, false)}, ${clock(s.starts_at)} to ${clock(s.ends_at)}`;

export default function ShiftsScreen() {
  const { api, config } = useApp();
  const shifts = useLoad<Shifts>('field.shifts', () => api.call('field.shifts') as Promise<{ ok: true; data: Shifts } | { ok: false; code: string; message: string }>);
  const { busy, error, act } = useAct();
  const run = async (action: 'shift_take' | 'shift_drop' | 'offer_claim', p: Record<string, unknown>, key: string) => {
    const r = await act(key, () => api.call('field.act', { body: { action, p } }));
    if (r.ok) { forgetLoaded('field.today'); shifts.reload(); }
  };
  if (shifts.loading) return <Busy label="Loading shifts" />;
  if (!shifts.data) return <Failed message={shifts.error ?? 'The shifts could not be loaded.'} onRetry={shifts.reload} />;
  const s = shifts.data;
  const open = s.open.filter((x) => !x.mine && x.taken < x.capacity);
  return (
    <Screen onRefresh={shifts.reload} refreshing={shifts.refreshing} testID="shifts">
      <Stack.Screen options={{ title: 'Shifts' }} />
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {s.locked ? <Notice tone="warn">Shifts are locked for you right now. Ask your manager.</Notice> : null}
      <H2 style={{ marginTop: 0 }}>Mine</H2>
      {!s.mine.length ? <Empty title="No shifts yet" body="Claim one below." /> : s.mine.map((x) => (
        <Card key={x.id}>
          <Row style={{ justifyContent: 'space-between' }}>
            <View style={{ flex: 1 }}><Text style={type.h3}>{span(x)}</Text>{x.note ? <Small>{x.note}</Small> : null}{x.standing ? <Small>Every week</Small> : null}</View>
            <Button label="Give up" variant="ghost" onPress={() => void run('shift_drop', { slot: x.id }, `drop-${x.id}`)} busy={busy === `drop-${x.id}`} style={{ marginBottom: 0 }} />
          </Row>
        </Card>
      ))}
      {s.offers.length ? <H2>Offered to you</H2> : null}
      {s.offers.map((o) => (
        <Card key={o.id}><Text style={type.h3}>{span(o)}</Text><Small>From {o.from}</Small>
          <Button label="Claim" onPress={() => void run('offer_claim', { id: o.id }, `offer-${o.id}`)} busy={busy === `offer-${o.id}`} /></Card>
      ))}
      <H2>Open shifts</H2>
      {!open.length ? <Small>No open shifts right now. New ones arrive as alerts.</Small> : open.map((x) => (
        <Card key={x.id} testID={`open-${x.id}`}>
          <Text style={type.h3}>{span(x)}</Text>
          <Small>{x.capacity - x.taken} of {x.capacity} places left{x.note ? ` · ${x.note}` : ''}</Small>
          <Button label="Claim this shift" onPress={() => void run('shift_take', { slot: x.id }, `take-${x.id}`)} busy={busy === `take-${x.id}`} testID={`claim-${x.id}`} />
        </Card>
      ))}
      <Button label="Availability, swaps and pay on carmacars.ca" variant="ghost" onPress={() => void openSite('/staff/field/shifts', config?.site_url)} />
    </Screen>
  );
}
