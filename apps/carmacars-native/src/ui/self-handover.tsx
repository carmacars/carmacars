import { useState } from 'react';
import { Text, View } from 'react-native';
import { Image } from 'expo-image';
import { Alert } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { forgetLoaded, useApp, useLoad } from '@/app-state';
import { ANGLES, FUEL_EIGHTHS, anglesDone, emptyReading, readingPayload, readingPhotos, readingProblem, readingValues, selfieLive, type ReadingState } from '@/shared';
import { locate, photoProblem, takePhoto } from '@/native';
import { loadTrip, type TripData } from '@/trip-data';
import { color, radius, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Chip, Failed, Field, H2, Notice, P, Row, Screen, Small, Wrap } from '@/ui/kit';

// Check in at the car, or check out when you bring it back, by yourself: photos of each side, the dashboard (odometer
// and fuel), a selfie at the car, then one button. The same records as the site's own check-in and "I've returned the
// car" (migrations 0532, 0545 and 0910): the database checks the booking, the photos and the readings. The suggested
// angles are guidance, as on the site; the dashboard photo, the odometer, the fuel and the selfie are what it needs.
interface Taken { bucket: string; path: string; angle: string | null; uri: string }

export function SelfHandover({ number, kind }: { number: string; kind: 'pickup' | 'return' }) {
  const out = kind === 'return';
  const { api } = useApp();
  const trip = useLoad<TripData>(`trip:${number}`, () => loadTrip(api, number));
  const [photos, setPhotos] = useState<Taken[]>([]);
  const [reading, setReading] = useState<ReadingState>(emptyReading);
  const [dashUri, setDashUri] = useState<string | null>(null);
  const [selfieUri, setSelfieUri] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ status: string; reason?: string } | null>(null);
  const router = useRouter();
  if (trip.loading) return <Busy />;
  if (!trip.data) return <Failed message={trip.error ?? 'Not loaded.'} onRetry={trip.reload} />;

  const upload = async (key: string, o: { front?: boolean } = {}) => {
    setError(null);
    const shot = await takePhoto(o);
    if (!shot.ok) { setError(photoProblem(shot)); return null; }
    setBusy(key);
    const r = await api.upload(out ? 'trip.returnPhoto' : 'trip.checkinPhoto', { number }, shot.shot);
    setBusy(null);
    if (!r.ok) { setError(r.message); return null; }
    return { ...r.data, uri: shot.shot.uri, takenAt: shot.shot.takenAt };
  };
  const angle = async (k: string) => { const p = await upload(k); if (p) setPhotos((x) => [...x.filter((y) => y.angle !== k || k === 'damage'), { bucket: p.bucket, path: p.path, angle: k, uri: p.uri }]); };
  const dash = async () => { const p = await upload('dashboard'); if (p) { setDashUri(p.uri); setReading((s) => ({ ...s, dash: { bucket: p.bucket, path: p.path } })); } };
  const selfie = async () => {
    const [p, fix] = await Promise.all([upload('selfie', { front: true }), locate()]);
    if (p) { setSelfieUri(p.uri); setReading((s) => ({ ...s, selfie: { bucket: p.bucket, path: p.path, taken_at: p.takenAt, live: selfieLive(Date.parse(p.takenAt)), latitude: fix?.lat ?? null, longitude: fix?.lng ?? null } })); }
  };
  const covered = anglesDone(photos);
  const walk = ANGLES.filter(([k]) => !['odometer', 'fuel', 'damage'].includes(k));
  const missing = walk.filter(([k]) => !covered.has(k));
  const problem = readingProblem(reading);

  const send = async () => {
    setBusy('submit'); setError(null);
    const v = readingValues(reading);
    const all = [...photos.map((p) => ({ bucket: p.bucket, path: p.path, angle: p.angle ?? undefined })), ...readingPhotos(reading)];
    const r = out
      ? await api.call('trip.return', { params: { number }, body: { returned_at: new Date().toISOString(), odometer_km: v.odometer_km, fuel_pct: v.fuel_pct, note: note.trim() || undefined, photos: all, reading: readingPayload(reading) } })
      : await api.call('trip.checkin', { params: { number }, body: { at: undefined, odometer_km: v.odometer_km, fuel_pct: v.fuel_pct, note: note.trim() || undefined, photos: all, reading: readingPayload(reading) } });
    setBusy(null);
    if (!r.ok) { setError(r.message); return; }
    forgetLoaded('trip'); setDone(r.data);
  };
  const submit = () => {
    if (problem) { setError(problem); return; }
    if (!missing.length) { void send(); return; }
    Alert.alert(`${missing.length} suggested photo${missing.length === 1 ? '' : 's'} not taken`, `Photos of every side protect you. Still to take: ${missing.slice(0, 4).map(([, l]) => l.toLowerCase()).join(', ')}${missing.length > 4 ? '…' : ''}.`,
      [{ text: 'Take them', style: 'cancel' }, { text: out ? 'Check out anyway' : 'Check in anyway', onPress: () => void send() }]);
  };

  if (done) {
    return (
      <Screen testID="checked-in">
        <Notice tone="ok" title={out ? 'Return reported' : done.status === 'on_rent' || done.status === 'completed' ? 'You are checked in' : 'Check-in sent'}>
          {done.reason ?? (out ? 'Thank you. Your photos and readings are saved; we confirm the return and release your deposit as the agreement says.' : 'Enjoy the drive. Your photos and readings are saved with your trip.')}
        </Notice>
        <Button label="Open my trip" onPress={() => router.replace(`/trip/${number}` as never)} />
      </Screen>
    );
  }
  return (
    <Screen testID={out ? 'checkout' : 'checkin'} footer={<><Button label={out ? 'I have returned the car' : 'Check in'} onPress={submit} busy={busy === 'submit'} testID="submit" />{problem ? <Small style={{ textAlign: 'center' }}>{problem}</Small> : null}</>}>
      <Stack.Screen options={{ title: out ? 'Check out' : 'Check in' }} />
      <P>{out ? 'Walk around the car and take each photo where you left it. They show how you returned it.' : 'Walk around the car and take each photo. They protect you: anything already on the car is on record before you drive.'}</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      <H2 style={{ marginTop: 0 }}>The car ({walk.length - missing.length} of {walk.length})</H2>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: space.sm }}>
        {walk.map(([k, label]) => {
          const p = photos.find((x) => x.angle === k);
          return (
            <View key={k} style={{ width: '31%' }}>
              <Card onPress={() => void angle(k)} label={`${label}${p ? ', taken' : ', to take'}`} style={{ padding: 0, overflow: 'hidden', marginBottom: 0, borderColor: p ? color.ok : color.line }} testID={`angle-${k}`}>
                {p ? <Image source={{ uri: p.uri }} style={{ width: '100%', aspectRatio: 1 }} contentFit="cover" /> : <View style={{ width: '100%', aspectRatio: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: color.field }}>{busy === k ? <Busy /> : <Text style={{ fontSize: 26, color: color.muted }}>＋</Text>}</View>}
                <Text style={[type.small, { padding: 6, textAlign: 'center', color: color.ink }]} numberOfLines={1}>{label}</Text>
              </Card>
            </View>
          );
        })}
      </View>
      <Button label={`Add a photo of damage${photos.filter((p) => p.angle === 'damage').length ? ` (${photos.filter((p) => p.angle === 'damage').length})` : ''}`} variant="outline" onPress={() => void angle('damage')} busy={busy === 'damage'} style={{ marginTop: space.md }} />

      <H2>The dashboard</H2>
      <Card>
        <Row style={{ justifyContent: 'space-between' }}><Text style={type.h3}>Odometer and fuel gauge</Text><Badge label={reading.dash ? 'Taken' : 'Needed'} tone={reading.dash ? 'ok' : 'red'} /></Row>
        {dashUri ? <Image source={{ uri: dashUri }} style={{ width: '100%', aspectRatio: 16 / 9, borderRadius: radius.sm, marginVertical: space.sm }} contentFit="cover" accessibilityLabel="Your photo of the dashboard" /> : null}
        <Button label={reading.dash ? 'Take it again' : 'Photograph the dashboard'} variant={reading.dash ? 'outline' : 'primary'} onPress={() => void dash()} busy={busy === 'dashboard'} testID="dash" />
        <Field label="Odometer (km)" value={reading.km} onChangeText={(v) => setReading((s) => ({ ...s, km: v.replace(/[^\d,\s]/g, '') }))} keyboardType="number-pad" testID="km" />
        <Text style={[type.label, { marginBottom: space.xs }]}>Fuel</Text>
        <Wrap>{FUEL_EIGHTHS.map(([label, pct]) => <Chip key={pct} label={label} on={reading.fuel === String(pct)} onPress={() => setReading((s) => ({ ...s, fuel: String(pct) }))} />)}</Wrap>
      </Card>

      <H2>You, at the car</H2>
      <Card>
        <Row style={{ justifyContent: 'space-between' }}><Text style={type.h3}>A selfie in front of the car</Text><Badge label={reading.selfie ? 'Taken' : 'Needed'} tone={reading.selfie ? 'ok' : 'red'} /></Row>
        <Small>{out ? 'Taken now with the camera: it shows when and where you returned the car.' : 'Taken now with the camera: it shows the driver who booked is the one picking up.'}</Small>
        {selfieUri ? <Image source={{ uri: selfieUri }} style={{ width: 140, aspectRatio: 3 / 4, borderRadius: radius.sm, marginVertical: space.sm }} contentFit="cover" accessibilityLabel="Your selfie" /> : null}
        <Button label={reading.selfie ? 'Take it again' : 'Take the selfie'} variant={reading.selfie ? 'outline' : 'primary'} onPress={() => void selfie()} busy={busy === 'selfie'} style={{ marginTop: space.sm }} testID="selfie" />
      </Card>
      <Field label="Anything to note? (optional)" value={note} onChangeText={setNote} multiline maxLength={2000} />
    </Screen>
  );
}
