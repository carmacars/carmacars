import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import type { AgreementBlock, AgreementView, EsignView } from '@/shared';
import { consentsLeft, initialsLeft, initialsOf, progress, stageOf } from '@/logic/esign';
import { locate, openSite } from '@/native';
import { color, space, type } from '@/theme';
import { Busy, Button, Card, Check, Failed, Field, H2, Notice, P, Row, Screen, Small } from '@/ui/kit';
import { SignaturePad } from '@/ui/inputs';

// Signing the rental agreement on the phone. It is the site's own signing session (migration 0154): the same document
// (its SHA-256 goes with the signature), the same steps recorded one by one with the time, the address and this
// phone's name, the same four statements and the same one-time code when Program settings ask for one. The record a
// signature leaves is identical to one made on the website.
export default function Sign() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api, config } = useApp();
  const router = useRouter();
  const doc = useLoad<AgreementView>(`agreement:${number}`, () => api.call('trip.agreement', { params: { number } }));
  const [view, setView] = useState<EsignView | null>(null);
  const { busy, error, act, setError } = useAct();
  const [code, setCode] = useState('');
  const [ticked, setTicked] = useState<string[]>([]);
  const [drawn, setDrawn] = useState<string | null>(null);
  const [typed, setTyped] = useState('');
  const [path, setPath] = useState<string | null>(null);

  const esign = async (name: string, body: Parameters<typeof api.call<'trip.esign'>>[1]['body']) => {
    const r = await act(name, () => api.call('trip.esign', { params: { number }, body }));
    if (r.ok) { setView(r.data); if (r.data.path) setPath(r.data.path); }
    return r;
  };
  const step = (name: string, s: Record<string, unknown>) => esign(name, { op: 'step', session: view!.id, step: s as never, channel: undefined, code: undefined, part: undefined });
  // the session starts when the document is on screen; where it is signed is recorded when the phone allows it
  useEffect(() => {
    if (!doc.data || view || doc.data.status !== 'open') return;
    void esign('start', { op: 'start', session: undefined, channel: undefined, code: undefined, step: undefined, part: undefined }).then((r) => {
      if (r.ok) void locate().then((fix) => { if (fix) void api.call('trip.esign', { params: { number }, body: { op: 'step', session: r.data.id, step: { kind: 'geolocation', lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy } as never, channel: undefined, code: undefined, part: undefined } }); });
    });
  }, [doc.data]); // eslint-disable-line react-hooks/exhaustive-deps

  if (doc.loading) return <Busy label="Opening your agreement" />;
  if (!doc.data) return <Failed message={doc.error ?? 'The agreement could not be opened.'} onRetry={doc.reload} />;
  const a = doc.data;
  if (a.status !== 'open') return <Screen><Notice tone="ok" title="Signed">This agreement is signed. The signed copy is in your documents.</Notice><Button label="Back to my trip" onPress={() => router.replace(`/trip/${number}` as never)} /></Screen>;
  if (!view) return error ? <Failed message={error} onRetry={doc.reload} /> : <Busy label="Starting the signing" />;
  // a signing picked up again later has its drawn signature on the server but not on this screen: it is drawn again
  const stage = stageOf(view) === 'ready' && view.signature === 'drawn' && !path ? 'signature' : stageOf(view);
  const prog = progress(view);
  const legal = a.legalName || view.signer_name;

  const finish = async () => {
    if (!a.consents.every((c) => ticked.includes(c.code))) { setError(`Tick all ${a.consents.length} statements to sign.`); return; }
    const r = await act('sign', () => api.call('trip.sign', { params: { number }, body: { consents: ticked, sha: a.sha, companionSha: a.companionSha ?? undefined, session: view.id,
      drawnPath: view.signature === 'drawn' ? path ?? undefined : undefined, typedName: view.signature === 'typed' ? typed.trim() || legal : undefined, drawn: undefined } }));
    if (!r.ok) return;
    forgetLoaded('trip'); forgetLoaded('agreement');
    // the site goes on to the payment when one is due; so does the app
    router.replace((r.next && /#pay/.test(r.next) ? `/trip/${number}/pay` : `/trip/${number}`) as never);
  };

  return (
    <Screen testID="sign" footer={stage === 'ready' ? <Button label="Sign the agreement" onPress={() => void finish()} busy={busy === 'sign'} testID="sign-now" /> : undefined}>
      <Stack.Screen options={{ title: 'Sign your agreement' }} />
      <Small>Step {Math.min(prog.done + 1, prog.total)} of {prog.total} · signing as {legal}</Small>
      <View accessibilityRole="progressbar" accessibilityValue={{ min: 0, max: prog.total, now: prog.done }} style={{ height: 6, borderRadius: 3, backgroundColor: color.line, marginVertical: space.sm }}>
        <View style={{ height: 6, borderRadius: 3, backgroundColor: color.red, width: `${Math.round((prog.done / prog.total) * 100)}%` }} />
      </View>
      {error ? <Notice tone="bad">{error}</Notice> : null}

      {stage === 'code' ? (<>
        <H2>Confirm it is you</H2>
        {view.code_sent_to ? (<>
          <P>We sent a 6-digit code to {view.code_sent_to}.</P>
          {view.devCode ? <Notice>Test code: {view.devCode}</Notice> : null}
          <Field label="Code" value={code} onChangeText={setCode} keyboardType="number-pad" textContentType="oneTimeCode" autoComplete="sms-otp" maxLength={7} />
          <Button label="Continue" onPress={() => void esign('check', { op: 'check_code', session: view.id, code, channel: undefined, step: undefined, part: undefined })} busy={busy === 'check'} disabled={code.replace(/\D/g, '').length !== 6} />
        </>) : <P>We send a one-time code before you sign.</P>}
        {view.channels.map((c) => <Button key={c.channel} label={`${view.code_sent_to ? 'Send a new code' : 'Send the code'} by ${c.channel === 'sms' ? 'text' : 'email'} to ${c.to}`} variant="outline"
          onPress={() => void esign(`send-${c.channel}`, { op: 'send_code', session: view.id, channel: c.channel, code: undefined, step: undefined, part: undefined })} busy={busy === `send-${c.channel}`} />)}
      </>) : null}

      {stage === 'read' ? (<>
        <H2>Read your agreement</H2>
        <Card style={{ backgroundColor: color.field }}>{a.blocks.map((b, i) => <Block key={i} b={b} />)}</Card>
        <Button label="Open the PDF" variant="ghost" onPress={() => void openSite(`/account/documents/${a.documentId}`, config?.site_url)} />
        <Button label="I have read the agreement" onPress={() => void step('viewed', { kind: 'viewed' })} busy={busy === 'viewed'} testID="viewed" />
      </>) : null}

      {stage === 'initials' ? (<>
        <H2>Initial the key terms</H2>
        {initialsLeft(view).slice(0, 1).map((c) => {
          const t = a.terms.find((x) => x.code === c);
          return (
            <Card key={c}>
              <Text style={type.h3}>{t?.title ?? c.replace(/_/g, ' ')}</Text>
              {t?.text ? <Text style={[type.body, { marginVertical: space.sm }]}>{t.text}</Text> : null}
              <Button label={`Initial: ${initialsOf(legal)}`} onPress={() => void step(`initial-${c}`, { kind: 'initial', code: c, typed: initialsOf(legal) })} busy={busy === `initial-${c}`} testID={`initial-${c}`} />
              <Small>{initialsLeft(view).length - 1} more after this one.</Small>
            </Card>
          );
        })}
      </>) : null}

      {stage === 'consents' ? (<>
        <H2>Signing electronically</H2>
        {view.required_consents.map((c) => (
          <Check key={c} label={a.esignConsents[c] ?? c} on={view.consents.includes(c)} onChange={(v) => { if (v && !view.consents.includes(c)) void step(`consent-${c}`, { kind: 'consent', code: c }); }} testID={`consent-${c}`} />
        ))}
        <Small>{consentsLeft(view).length} left to tick.</Small>
      </>) : null}

      {stage === 'signature' ? (<>
        <H2>Your signature</H2>
        <SignaturePad label={`Sign as ${legal}`} onSigned={setDrawn} />
        <Button label="Use this signature" onPress={() => void step('signature', { kind: 'signature', png: drawn })} busy={busy === 'signature'} disabled={!drawn} testID="use-signature" />
        {view.typed_fallback_allowed ? (<>
          <Small style={{ textAlign: 'center', marginVertical: space.sm }}>or type your full legal name</Small>
          <Field label="Full legal name" value={typed} onChangeText={setTyped} autoCapitalize="words" />
          <Button label="Sign with my typed name" variant="outline" onPress={() => void step('signature', { kind: 'signature', typed: typed.trim() })} disabled={typed.trim().length < 3} />
        </>) : null}
      </>) : null}

      {stage === 'ready' ? (<>
        <H2>Last step</H2>
        {a.consents.map((c) => <Check key={c.code} label={`${c.title}. ${c.text}`} on={ticked.includes(c.code)} onChange={(v) => setTicked((p) => (v ? [...new Set([...p, c.code])] : p.filter((x) => x !== c.code)))} testID={`statement-${c.code}`} />)}
        <Row><Button label="Tick all" variant="ghost" onPress={() => setTicked(a.consents.map((c) => c.code))} /></Row>
        <P>{a.statement}</P>
      </>) : null}
      {stage === 'done' ? <Notice tone="ok" title="Signed">Your signature is recorded.</Notice> : null}
    </Screen>
  );
}

function Block({ b }: { b: AgreementBlock }) {
  if (b.t === 'title') return <Text style={[type.h2, { marginBottom: space.sm }]}>{b.text}</Text>;
  if (b.t === 'h2' || b.t === 'h3') return <Text style={[type.h3, { marginTop: space.md, marginBottom: space.xs }]}>{b.text}</Text>;
  if (b.t === 'p') return <Text style={[type.body, { marginBottom: space.sm }]}>{b.text}</Text>;
  if (b.t === 'ul' || b.t === 'ol') return <View style={{ marginBottom: space.sm }}>{(b.items ?? []).map((it, i) => <Text key={i} style={type.body}>{b.t === 'ol' ? `${i + 1}. ` : '• '}{it}</Text>)}</View>;
  if (b.t === 'table') return <View style={{ marginBottom: space.sm }}>{((b.rows ?? []) as string[][]).map((r, i) => <Text key={i} style={type.body}><Text style={{ fontWeight: '700' }}>{r[0]}</Text>{r.length > 1 ? `: ${r.slice(1).join(' · ')}` : ''}</Text>)}</View>;
  return null;
}
