import { useEffect, useMemo, useState } from 'react';
import { Alert, Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { CLEANLINESS, DAMAGE_KINDS, emptyDraft, firstProblem, LOCATIONS, reportPayload, sections, shotName, type Damage, type Draft, type JobFacts } from '@/logic/field';
import { FUEL_EIGHTHS } from '@/shared';
import { clock, when } from '@/logic/format';
import { locate, openSite, photoProblem, takePhoto } from '@/native';
import { color, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Check, Chip, Failed, Field, H2, Notice, Pair, Row, Screen, Small, Wrap } from '@/ui/kit';
import { SignaturePad } from '@/ui/inputs';

// A field job: the handover checklist. Photos of each required shot with the phone's camera (each saved to the job's
// report as it is taken, with the time and the place), the odometer, fuel and keys, any damage, the licence and card
// checks, and both signatures; then one button. The database completes the pickup or the return in one step and refuses
// anything missing, exactly as on the site; an interrupted job opens where it was left.
interface Job {
  job: { id: string; kind: string; status: string; scheduled_at: string; place: string | null; instructions: string | null; started_at: string | null; completed_at: string | null };
  report_kind: 'pickup' | 'return' | 'ready' | null; details_later?: boolean;
  vehicle: { name: string; plate: string | null; colour: string | null; odometer_km: number | null };
  booking: null | { booking_number: string; status: string; unattended: boolean; odometer_out_km: number | null; renter: { name: string; mobile: string | null } | null; drivers: Array<{ name: string; role: string; verified: boolean }>; extras: string[] };
  ready: null | { identity: boolean; coverage: boolean; agreement: boolean; deposit: string; signed?: boolean };
  shots: Array<{ seq: number; shot: string; guide: string | null }>;
  report: null | { odometer_km: number | null; fuel_pct: number | null; keys_count: number | null; cleanliness: string | null; completed_at: string | null; photos: Array<{ seq: number; shot: string }>; damages: Damage[]; problems: string[] };
  defaults?: { odometer_km?: number | null; fuel_pct?: number | null } | null;
}

export default function JobScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { api, config } = useApp();
  const router = useRouter();
  const job = useLoad<Job>(`field.job:${id}`, () => api.call('field.job', { params: { id } }) as Promise<{ ok: true; data: Job } | { ok: false; code: string; message: string }>);
  const { busy, error, act, setError } = useAct();
  const [d, setD] = useState<Draft | null>(null);
  const [block, setBlock] = useState<string | null>(null);
  const [finished, setFinished] = useState<string | null>(null);
  const j = job.data;
  useEffect(() => { if (j && !d) setD(emptyDraft(j.report, j.defaults)); }, [j, d]);
  const facts: JobFacts | null = useMemo(() => (j ? { kind: j.report_kind, shots: j.shots, unattended: !!j.booking?.unattended, detailsLater: !!j.details_later, odometerOutKm: j.booking?.odometer_out_km ?? null } : null), [j]);

  if (job.loading) return <Busy label="Loading the job" />;
  if (!j || !facts) return <Failed message={job.error ?? 'This job could not be loaded.'} onRetry={job.reload} />;
  const set = (p: Partial<Draft>) => setD((x) => (x ? { ...x, ...p } : x));
  const run = (action: Parameters<typeof api.call<'field.act'>>[1]['body']['action'], p: Record<string, unknown>) => act(action, () => api.call('field.act', { body: { action, p: { job: id, ...p } } }));
  const title = j.report_kind === 'pickup' ? 'Hand over' : j.report_kind === 'return' ? 'Take back' : j.job.kind.replace(/_/g, ' ');
  const started = !!j.job.started_at;
  const done = !!j.job.completed_at || !!finished;

  const start = async () => {
    if (j.job.status === 'scheduled') { const a = await run('acknowledge', {}); if (!a.ok) return; }
    const s = await run('start', {});
    if (s.ok) job.reload();
  };
  const shoot = async (shot: { seq: number; shot: string }, label?: string) => {
    setError(null);
    const [p, fix] = await Promise.all([takePhoto(), locate()]);
    if (!p.ok) { setError(photoProblem(p)); return; }
    const r = await act(`shot-${shot.shot}`, () => api.upload('field.photo', { id }, p.shot, { shot: shot.shot, seq: String(shot.seq), taken_at: p.shot.takenAt, width: String(p.shot.width), height: String(p.shot.height),
      ...(fix ? { latitude: String(fix.lat), longitude: String(fix.lng) } : {}), ...(label ? { damage_label: label } : {}) }));
    if (r.ok) setD((x) => (x ? { ...x, shotsDone: [...new Set([...x.shotsDone, shot.shot])] } : x));
  };
  const sign = async (who: 'renter' | 'staff', file: string | null) => {
    if (!file) { set(who === 'renter' ? { renter_signature_ref: null } : { staff_signature_ref: null }); return; }
    const r = await act(`sign-${who}`, () => api.upload('field.photo', { id }, { uri: file, name: `signature-${who}.png`, type: 'image/png' }, { shot: `signature_${who}`, seq: who === 'renter' ? '900' : '901', mode: 'raw', taken_at: new Date().toISOString() }));
    if (r.ok) set(who === 'renter' ? { renter_signature_ref: r.data.key } : { staff_signature_ref: r.data.key });
  };
  const save = async () => { if (d) await run('save_report', { report: reportPayload(facts, d) }); };
  const complete = async () => {
    if (!d) return;
    const problem = firstProblem(facts, d);
    if (problem) { setError(problem); return; }
    const r = await run(j.report_kind === 'pickup' ? 'complete_handover' : 'complete_return', { report: reportPayload(facts, d) });
    if (r.ok) { forgetLoaded('field.'); setFinished(j.report_kind === 'pickup' ? 'The car is handed over. The renter\'s trip has started.' : 'The car is back. The return is recorded.'); }
  };
  const stop = async () => { const r = await run('block_handover', { reason: block ?? '' }); if (r.ok) { forgetLoaded('field.'); router.back(); } };
  const parts = d ? sections(facts, d) : [];
  const partDone = (k: string) => parts.find((s) => s.key === k)?.done ?? false;
  const head = (k: string, t: string) => <Row style={{ justifyContent: 'space-between', marginTop: space.lg, marginBottom: space.sm }}><Text style={type.h2}>{t}</Text><Badge label={partDone(k) ? 'Done' : 'To do'} tone={partDone(k) ? 'ok' : 'red'} /></Row>;

  return (
    <Screen testID="field-job" onRefresh={job.reload} refreshing={job.refreshing}
      footer={started && !done && d && (j.report_kind === 'pickup' || j.report_kind === 'return') ? (<>
        <Button label={j.report_kind === 'pickup' ? 'Complete the handover' : 'Complete the return'} onPress={() => void complete()} busy={busy === 'complete_handover' || busy === 'complete_return'} testID="complete" />
        {firstProblem(facts, d) ? <Small style={{ textAlign: 'center' }}>{firstProblem(facts, d)}</Small> : null}
      </>) : undefined}>
      <Stack.Screen options={{ title }} />
      <Text style={type.h1}>{title}: {j.vehicle.name}</Text>
      <Small>{[j.vehicle.plate, j.vehicle.colour, clock(j.job.scheduled_at), j.job.place].filter(Boolean).join(' · ')}</Small>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {finished ? <Notice tone="ok" title="Done">{finished}</Notice> : null}
      {j.booking ? (
        <Card style={{ marginTop: space.md }}>
          <Pair k="Booking" v={j.booking.booking_number} />
          {j.booking.renter ? <Pair k="Renter" v={j.booking.renter.name} /> : null}
          {j.booking.drivers.map((x) => <Pair key={x.name} k={x.role === 'renter' ? 'Driver' : 'Additional driver'} v={`${x.name}${x.verified ? ' · verified' : ' · not verified'}`} />)}
          {j.ready ? <Wrap style={{ marginTop: space.sm }}>
            <Badge label={j.ready.identity ? 'Identity ok' : 'Identity missing'} tone={j.ready.identity ? 'ok' : 'red'} />
            <Badge label={j.ready.agreement ? 'Agreement signed' : 'Agreement not signed'} tone={j.ready.agreement ? 'ok' : 'red'} />
            <Badge label={`Deposit ${j.ready.deposit.replace(/_/g, ' ')}`} tone={['taken', 'waived', 'none'].includes(j.ready.deposit) ? 'ok' : 'red'} />
          </Wrap> : null}
          {j.booking.extras.length ? <Small style={{ marginTop: space.sm }}>To put in the car: {j.booking.extras.join(', ')}</Small> : null}
        </Card>
      ) : null}
      {j.job.instructions ? <Notice title="Instructions">{j.job.instructions}</Notice> : null}

      {done ? <Button label="Back to today" onPress={() => router.back()} /> : !started ? (
        <Button label="Start this job" onPress={() => void start()} busy={busy === 'start' || busy === 'acknowledge'} testID="start" />
      ) : j.report_kind !== 'pickup' && j.report_kind !== 'return' ? (
        <Notice tone="warn" title="This job's checklist is on carmacars.ca"><Button label="Open it" onPress={() => void openSite(`/staff/field/jobs/${id}`, config?.site_url)} /></Notice>
      ) : !d ? <Busy /> : (<>
        {head('photos', `Photos (${j.shots.filter((s) => d.shotsDone.includes(s.shot)).length} of ${j.shots.length})`)}
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: space.sm }}>
          {j.shots.map((s) => {
            const got = d.shotsDone.includes(s.shot);
            return (
              <View key={s.shot} style={{ width: '48%' }}>
                <Card onPress={() => void shoot(s)} label={`${shotName(s.shot)}${got ? ', taken' : ', to take'}`} style={{ marginBottom: 0, borderColor: got ? color.ok : color.line, padding: space.md }} testID={`shot-${s.shot}`}>
                  <Row style={{ justifyContent: 'space-between' }}><Text style={type.h3}>{shotName(s.shot)}</Text><Text style={{ color: got ? color.ok : color.muted, fontSize: 18 }}>{busy === `shot-${s.shot}` ? '…' : got ? '✓' : '＋'}</Text></Row>
                  {s.guide ? <Text style={type.small} numberOfLines={2}>{s.guide}</Text> : null}
                </Card>
              </View>
            );
          })}
        </View>

        {head('readings', 'Odometer, fuel and keys')}
        <Field label="Odometer (km)" value={d.odometer_km} onChangeText={(v) => set({ odometer_km: v.replace(/[^\d,\s]/g, '') })} keyboardType="number-pad" testID="odometer" help={j.booking?.odometer_out_km ? `At pickup: ${j.booking.odometer_out_km.toLocaleString('en-CA')} km` : undefined} />
        <Text style={[type.label, { marginBottom: space.xs }]}>Fuel</Text>
        <Wrap>{FUEL_EIGHTHS.map(([label, pct]) => <Chip key={pct} label={label} on={d.fuel_pct === pct} onPress={() => set({ fuel_pct: pct })} />)}</Wrap>
        <Text style={[type.label, { marginTop: space.md, marginBottom: space.xs }]}>Keys</Text>
        <Wrap>{[1, 2, 3].map((n) => <Chip key={n} label={String(n)} on={d.keys_count === n} onPress={() => set({ keys_count: n })} />)}</Wrap>
        <Text style={[type.label, { marginTop: space.md, marginBottom: space.xs }]}>Cleanliness</Text>
        <Wrap>{CLEANLINESS.map(([v, label]) => <Chip key={v} label={label} on={d.cleanliness === v} onPress={() => set({ cleanliness: v })} />)}</Wrap>

        {head('damage', `Damage (${d.damages.length})`)}
        {d.damages.map((x, i) => (
          <Card key={i}>
            <Wrap>{LOCATIONS.map((l) => <Chip key={l} label={l} on={x.location === l} onPress={() => set({ damages: d.damages.map((y, k) => (k === i ? { ...y, location: l } : y)) })} />)}</Wrap>
            <Wrap style={{ marginVertical: space.sm }}>{DAMAGE_KINDS.map((k) => <Chip key={k} label={k} on={x.kind === k} onPress={() => set({ damages: d.damages.map((y, n) => (n === i ? { ...y, kind: k } : y)) })} />)}</Wrap>
            <Field label="What it is" value={x.description} onChangeText={(v) => set({ damages: d.damages.map((y, n) => (n === i ? { ...y, description: v, label: v.slice(0, 60) } : y)) })} placeholder="4 cm scratch, left of the plate" />
            <Check label="New since the last report" on={x.is_new} onChange={(v) => set({ damages: d.damages.map((y, n) => (n === i ? { ...y, is_new: v } : y)) })} />
            <Row><Button label="Photograph it" variant="outline" onPress={() => void shoot({ seq: 500 + i, shot: 'damage' }, x.description.slice(0, 60) || x.location)} style={{ flex: 1 }} /><Button label="Remove" variant="ghost" onPress={() => set({ damages: d.damages.filter((_, n) => n !== i) })} style={{ flex: 1 }} /></Row>
          </Card>
        ))}
        <Button label="Add damage" variant="outline" onPress={() => set({ damages: [...d.damages, { label: '', location: 'other', description: '', kind: 'scratch', size_cm: null, position: null, is_new: true }] })} testID="add-damage" />

        {parts.some((s) => s.key === 'checks') ? (<>
          {head('checks', 'Licence and card')}
          <Check label="I saw the driver's licence and it matches the booking" on={d.licence_seen} onChange={(v) => set({ licence_seen: v })} testID="licence-seen" />
          <Check label="I saw the card and it is in the renter's name" on={d.card_seen} onChange={(v) => set({ card_seen: v })} testID="card-seen" />
        </>) : null}

        {head('signatures', 'Signatures')}
        {!facts.unattended && !facts.detailsLater ? (<>
          {j.report_kind === 'return' ? <Check label="The renter is here" on={d.renter_present} onChange={(v) => set({ renter_present: v })} /> : null}
          {d.renter_present && !d.renter_declined_to_sign ? <SignaturePad as="file" label={`${j.booking?.renter?.name ?? 'The renter'} signs`} onSigned={(f) => void sign('renter', f)} /> : null}
          {d.renter_signature_ref ? <Small style={{ color: color.ok }}>Renter's signature saved.</Small> : null}
          {j.report_kind === 'return' && d.renter_present ? (<>
            <Check label="The renter would not sign" on={d.renter_declined_to_sign} onChange={(v) => set({ renter_declined_to_sign: v })} />
            {d.renter_declined_to_sign ? <Field label="Why" value={d.renter_decline_reason} onChangeText={(v) => set({ renter_decline_reason: v })} /> : null}
          </>) : null}
        </>) : <Small>No renter signature on this one.</Small>}
        <SignaturePad as="file" label="You sign, for CarmaCars" onSigned={(f) => void sign('staff', f)} />
        {d.staff_signature_ref ? <Small style={{ color: color.ok }}>Your signature saved.</Small> : null}
        <Field label="Notes (optional)" value={d.notes} onChangeText={(v) => set({ notes: v })} multiline />
        <Button label="Save and finish later" variant="outline" onPress={() => void save()} busy={busy === 'save_report'} />
        {j.report_kind === 'pickup' ? (block === null ? <Button label="The car cannot go out" variant="ghost" onPress={() => setBlock('')} /> : (<>
          <Field label="Why the handover is stopped" value={block} onChangeText={setBlock} multiline />
          <Button label="Stop the handover" variant="danger" onPress={() => Alert.alert('Stop this handover?', 'The office is told at once.', [{ text: 'Cancel', style: 'cancel' }, { text: 'Stop it', style: 'destructive', onPress: () => void stop() }])} disabled={block.trim().length < 5} busy={busy === 'block_handover'} />
        </>)) : null}
        <Small style={{ marginTop: space.sm }}>Started {when(j.job.started_at)}</Small>
      </>)}
    </Screen>
  );
}
