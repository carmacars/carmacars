import { useState } from 'react';
import { Text, View } from 'react-native';
import { Image } from 'expo-image';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useApp, useLoad } from '@/app-state';
import { API_URL, fileBlob, photoProblem, takePhoto, type Shot } from '@/native';
import { loadTrip, type TripData } from '@/trip-data';
import { radius, space, type } from '@/theme';
import { Badge, Busy, Button, Card, Failed, Field, H2, Notice, P, Row, Screen, Small } from '@/ui/kit';
import { WhenField } from '@/ui/inputs';

// The driver's licence (front and back) and a selfie, taken with the camera. Each photo goes straight to the site's
// private storage with a one-time upload link, then the site checks the file and reads the licence; a photo it cannot
// use is asked for again on the spot, with the reason.
type Kind = 'licence_front' | 'licence_back' | 'selfie';
const STEPS: Array<{ kind: Kind; title: string; help: string; front?: boolean }> = [
  { kind: 'licence_front', title: 'Front of your licence', help: 'Flat, in good light, all four corners in the photo.' },
  { kind: 'licence_back', title: 'Back of your licence', help: 'The barcode sharp and whole.' },
  { kind: 'selfie', title: 'A selfie', help: 'Your face, no hat or sunglasses, holding nothing.', front: true }
];

export default function Verify() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api } = useApp();
  const router = useRouter();
  const trip = useLoad<TripData>(`trip:${number}`, () => loadTrip(api, number));
  const [busy, setBusy] = useState<Kind | 'licence' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retake, setRetake] = useState<Partial<Record<Kind, string>>>({});
  const [taken, setTaken] = useState<Partial<Record<Kind, Shot>>>({});
  const [lic, setLic] = useState({ licence_number: '', licence_class: 'G', licence_issuer: 'ON', licence_expiry: '' });
  const [licSaved, setLicSaved] = useState(false);
  if (trip.loading) return <Busy />;
  if (!trip.data) return <Failed message={trip.error ?? 'Not loaded.'} onRetry={trip.reload} />;
  const b = trip.data.booking;
  const driver = b.drivers.find((d) => d.role === 'renter') ?? b.drivers[0];
  const stateOf = (k: Kind) => b.uploads.filter((u) => u.kind === k && u.status !== 'replaced' && (!driver || u.driver_id === driver.driver_id)).at(-1) ?? null;

  const capture = async (k: Kind, o: { front?: boolean; library?: boolean }) => {
    setError(null);
    if (!driver) { setError('This booking has no driver yet. Open it on carmacars.ca.'); return; }
    const shot = await takePhoto(o);
    if (!shot.ok) { setError(photoProblem(shot)); return; }
    setBusy(k);
    try {
      const blob = await fileBlob(shot.shot.uri);
      const slot = await api.call('trip.upload', { params: { number }, body: { kind: k, driverId: driver.driver_id, contentType: 'image/jpeg', size: blob.size } });
      if (!slot.ok) { setError(slot.message); return; }
      const url = slot.data.url.startsWith('/') ? `${API_URL}${slot.data.url}` : slot.data.url;
      const put = await fetch(url, { method: 'PUT', headers: { ...slot.data.headers, 'content-type': 'image/jpeg' }, body: blob });
      if (!put.ok) { setError('The photo did not upload. Check your connection and try again.'); return; }
      const done = await api.call('upload.confirm', { body: { ticket: slot.data.ticket, details: undefined } });
      if (!done.ok) { setError(done.message); return; }
      const again = (done.data as { retake?: string | null } | null)?.retake ?? null;
      setRetake((r) => ({ ...r, [k]: again ?? undefined }));
      setTaken((t) => ({ ...t, [k]: shot.shot }));
      forgetLoaded('trips'); trip.reload();
    } catch { setError('The photo did not upload. Check your connection and try again.'); } finally { setBusy(null); }
  };
  const saveLicence = async () => {
    setBusy('licence'); setError(null);
    const r = await api.call('trip.licence', { params: { number }, body: lic });
    setBusy(null);
    if (r.ok) { setLicSaved(true); trip.reload(); } else setError(r.message);
  };

  return (
    <Screen testID="verify" onRefresh={trip.reload} refreshing={trip.refreshing}>
      <Stack.Screen options={{ title: 'Licence and selfie' }} />
      <P>We check that the driver is who they say and holds a valid licence. The photos are kept private and removed after the rental, as the privacy policy says.</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {STEPS.map((s) => {
        const u = stateOf(s.kind);
        const need = !u || u.status === 'rejected' || !!retake[s.kind];
        return (
          <Card key={s.kind} testID={`step-${s.kind}`}>
            <Row style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
              <View style={{ flex: 1 }}><Text style={type.h3}>{s.title}</Text><Small>{s.help}</Small></View>
              <Badge label={!u ? 'Needed' : retake[s.kind] ? 'Take again' : u.status === 'approved' ? 'Approved' : u.status === 'rejected' ? 'Not accepted' : 'Sent'} tone={!u || u.status === 'rejected' || retake[s.kind] ? 'red' : u.status === 'approved' ? 'ok' : 'muted'} />
            </Row>
            {retake[s.kind] ? <Notice tone="warn">{retake[s.kind]}</Notice> : u?.status === 'rejected' && u.reject_reason ? <Notice tone="warn">{u.reject_reason}</Notice> : null}
            {taken[s.kind] ? <Image source={{ uri: taken[s.kind]!.uri }} style={{ width: '100%', aspectRatio: 16 / 10, borderRadius: radius.sm, marginTop: space.sm }} contentFit="cover" accessibilityLabel={`Your photo: ${s.title}`} /> : null}
            <View style={{ marginTop: space.md }}>
              <Button label={need ? 'Open the camera' : 'Take it again'} variant={need ? 'primary' : 'outline'} onPress={() => void capture(s.kind, { front: s.front })} busy={busy === s.kind} testID={`camera-${s.kind}`} />
              {s.kind !== 'selfie' ? <Button label="Choose a photo instead" variant="ghost" onPress={() => void capture(s.kind, { library: true })} /> : null}
            </View>
          </Card>
        );
      })}
      <H2>Licence details</H2>
      {licSaved ? <Notice tone="ok">Saved.</Notice> : null}
      <Small style={{ marginBottom: space.sm }}>We read these from your photo when we can. Fill them in if we ask, or to be sure.</Small>
      <Field label="Licence number" value={lic.licence_number} onChangeText={(v) => setLic({ ...lic, licence_number: v })} autoCapitalize="characters" autoCorrect={false} />
      <Row style={{ alignItems: 'flex-start' }}>
        <View style={{ flex: 1 }}><Field label="Class" value={lic.licence_class} onChangeText={(v) => setLic({ ...lic, licence_class: v.toUpperCase() })} autoCapitalize="characters" /></View>
        <View style={{ flex: 1 }}><Field label="Province or country" value={lic.licence_issuer} onChangeText={(v) => setLic({ ...lic, licence_issuer: v })} autoCapitalize="characters" /></View>
      </Row>
      <WhenField label="Expiry date" mode="date" value={lic.licence_expiry} onChange={(v) => setLic({ ...lic, licence_expiry: v })} />
      <Button label="Save the details" variant="outline" onPress={() => void saveLicence()} busy={busy === 'licence'} disabled={lic.licence_number.trim().length < 3 || !lic.licence_expiry} />
      <Button label="Done" onPress={() => router.back()} testID="done" />
    </Screen>
  );
}
