import { useRef, useState } from 'react';
import { Text } from 'react-native';
import * as Crypto from 'expo-crypto';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { forgetLoaded, useAct, useApp, useLoad } from '@/app-state';
import { ago, when } from '@/logic/format';
import { space, type } from '@/theme';
import { Badge, Busy, Button, Card, Chip, Failed, Field, H2, Notice, Pair, Row, Screen, Small, Wrap } from '@/ui/kit';

// One lead. Calling and texting go through the platform: the app only ever holds the masked number it was shown
// ("(647) •••-••00"); the server finds the real one, places the call from the CarmaCars number (your phone rings first)
// or sends the text from the CarmaCars line, and keeps both in the lead's history. Same rules as the site.
interface Lead { id: string; type: string; source: string; name: string | null; phone: string | null; email: string | null; message: string | null; vehicle: string | null; created_at: string; status: string; outcome: string | null;
  claim: { name: string; until: string; mine: boolean } | null; hold?: { name: string; locked: boolean } | null; handled_at: string | null; phone_unlocked?: boolean; phone_ask_open?: boolean; form: Record<string, string>;
  contacts: Array<{ at: string; channel: string; note: string | null; by: string }>; calls: Array<{ at: string; kind: string; direction: string; missed: boolean; text: string | null }>;
  history: Array<{ at: string; action: string; who: string; note: string | null }> }
const OUTCOMES: Array<[string, string]> = [['contacted', 'Contacted'], ['call_booked', 'Call booked'], ['applied', 'Applied'], ['won', 'Won'], ['lost', 'Lost']];

export default function LeadScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { api } = useApp();
  const router = useRouter();
  const lead = useLoad<Lead>(`sales.lead:${id}`, () => api.call('sales.lead', { params: { id } }) as Promise<{ ok: true; data: Lead } | { ok: false; code: string; message: string }>);
  const buttons = useLoad<{ quo?: boolean; twilio?: boolean; browser?: boolean; twilio_why?: string | null }>('sales.phone', () => api.call('sales.phoneButtons') as Promise<{ ok: true; data: { quo?: boolean; twilio?: boolean; browser?: boolean; twilio_why?: string | null } } | { ok: false; code: string; message: string }>);
  const { busy, error, act } = useAct();
  const [note, setNote] = useState<string | null>(null);
  const [panel, setPanel] = useState<'text' | 'note' | 'outcome' | null>(null);
  const [body, setBody] = useState('');
  const [outcome, setOutcome] = useState('contacted');
  const [reason, setReason] = useState('');
  const sendKey = useRef(Crypto.randomUUID());
  if (lead.loading) return <Busy label="Loading the lead" />;
  if (!lead.data) return <Failed message={lead.error ?? 'This lead could not be loaded.'} onRetry={lead.reload} />;
  const l = lead.data;
  const closed = !!l.handled_at || l.outcome === 'won' || l.outcome === 'lost';
  const mine = !!l.claim?.mine;
  // the buttons as the site decides them: texts need the CarmaCars line, calls need the calling service (the app rings your own phone first)
  const canText = buttons.data?.quo !== false;
  const canCall = !buttons.data || !!buttons.data.twilio || !!buttons.data.browser;
  const said = (text: string) => { setNote(text); setPanel(null); forgetLoaded('sales.leads'); lead.reload(); };
  const run = async (action: 'lead_claim' | 'lead_unclaim' | 'lead_contact' | 'lead_outcome' | 'lead_handled' | 'lead_phone_ask', p: Record<string, unknown>, ok: string) => {
    const r = await act(action, () => api.call('sales.leadAct', { body: { action, p: { lead: id, ...p } } }));
    if (r.ok) said(ok);
  };
  const call = async () => {
    if (!l.phone) return;
    const r = await act('call', () => api.call('sales.phone', { body: { action: 'phone_call', number: l.phone!, name: l.name ?? undefined, body: undefined, booking_number: undefined, key: undefined } }));
    if (!r.ok) return;
    const d = r.data as { message?: string };
    await api.call('sales.leadAct', { body: { action: 'lead_contact', p: { lead: id, channel: 'call' } } });
    said(d.message ?? 'Calling: your phone rings first, then we connect you from the CarmaCars number.');
  };
  const text = async () => {
    if (!l.phone || body.trim().length < 2) return;
    const r = await act('text', () => api.call('sales.phone', { body: { action: 'phone_compose', number: l.phone!, body: body.trim(), name: l.name ?? undefined, key: sendKey.current, booking_number: undefined } }));
    if (!r.ok) return;
    sendKey.current = Crypto.randomUUID(); setBody('');
    await api.call('sales.leadAct', { body: { action: 'lead_contact', p: { lead: id, channel: 'text' } } });
    said('Text sent from the CarmaCars number.');
  };

  return (
    <Screen testID="lead" onRefresh={lead.reload} refreshing={lead.refreshing}>
      <Stack.Screen options={{ title: 'Lead' }} />
      <Text style={type.h1}>{l.name ?? 'No name yet'}</Text>
      <Row style={{ marginBottom: space.md }}><Badge label={l.outcome ?? l.status} tone={l.outcome === 'won' ? 'ok' : l.outcome === 'lost' ? 'muted' : 'dark'} /><Small>{l.source} · {ago(l.created_at)}</Small></Row>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {note ? <Notice tone="ok">{note}</Notice> : null}
      <Card>
        {l.phone ? <Pair k="Phone" v={l.phone} /> : null}
        {l.email ? <Pair k="Email" v={l.email} /> : null}
        {l.vehicle ? <Pair k="About" v={l.vehicle} /> : null}
        {Object.entries(l.form ?? {}).slice(0, 8).map(([k, v]) => <Pair key={k} k={k.replace(/_/g, ' ')} v={String(v)} />)}
        {l.message ? <Text style={[type.body, { marginTop: space.sm }]}>{l.message}</Text> : null}
        <Small style={{ marginTop: space.sm }}>{l.claim ? (mine ? `Yours until ${when(l.claim.until)}` : `Claimed by ${l.claim.name}`) : l.hold?.locked ? `${l.hold.name} is handling a call` : 'Not claimed'}</Small>
      </Card>

      {!closed && !l.claim && !l.hold?.locked ? <Button label="Claim this lead" onPress={() => void run('lead_claim', {}, 'Claimed: it is yours.')} busy={busy === 'lead_claim'} testID="claim" /> : null}
      {l.phone ? (
        <Row>
          <Button label="Call" variant="dark" onPress={() => void call()} busy={busy === 'call'} disabled={!canCall} style={{ flex: 1 }} testID="call" />
          <Button label="Text" variant="outline" onPress={() => setPanel(panel === 'text' ? null : 'text')} disabled={!canText} style={{ flex: 1 }} testID="text" />
        </Row>
      ) : <Small>No phone number on this lead.</Small>}
      {!canCall && buttons.data ? <Small>{buttons.data.twilio_why ?? 'Calls from the platform are off right now.'}</Small> : null}
      <Small>Calls and texts go out from the CarmaCars number. The lead never sees yours, and theirs stays masked.</Small>
      {l.phone && /•/.test(l.phone) && !l.phone_unlocked ? <Button label={l.phone_ask_open ? 'Asked an Admin to show the number' : 'Ask an Admin to show the number'} variant="ghost" disabled={!!l.phone_ask_open} onPress={() => void run('lead_phone_ask', {}, 'Asked. You get an alert when it is shown.')} /> : null}
      {panel === 'text' ? (<>
        <Field label="Your text" value={body} onChangeText={setBody} multiline maxLength={1000} />
        <Button label="Send from the CarmaCars number" onPress={() => void text()} busy={busy === 'text'} disabled={body.trim().length < 2} testID="send-text" />
      </>) : null}

      <Button label="Send an offer" onPress={() => router.push({ pathname: '/sales/offer', params: { lead: id, name: l.name ?? '', email: l.email ?? '' } } as never)} testID="offer" />
      <Row>
        <Button label="Add a note" variant="outline" onPress={() => setPanel(panel === 'note' ? null : 'note')} style={{ flex: 1 }} />
        <Button label="Outcome" variant="outline" onPress={() => setPanel(panel === 'outcome' ? null : 'outcome')} style={{ flex: 1 }} />
      </Row>
      {panel === 'note' ? (<>
        <Field label="Note" value={body} onChangeText={setBody} multiline maxLength={1000} />
        <Button label="Save the note" onPress={() => void run('lead_contact', { channel: 'note', note: body.trim() }, 'Note saved.').then(() => setBody(''))} disabled={body.trim().length < 2} busy={busy === 'lead_contact'} />
      </>) : null}
      {panel === 'outcome' ? (<>
        <Wrap style={{ marginBottom: space.md }}>{OUTCOMES.map(([v, label]) => <Chip key={v} label={label} on={outcome === v} onPress={() => setOutcome(v)} />)}</Wrap>
        {outcome === 'lost' ? <Field label="Why it was lost" value={reason} onChangeText={setReason} maxLength={300} /> : null}
        <Button label="Save the outcome" onPress={() => void run('lead_outcome', { outcome, reason: reason.trim(), booking: '' }, 'Saved.')} disabled={outcome === 'lost' && reason.trim().length < 2} busy={busy === 'lead_outcome'} />
      </>) : null}
      {!closed ? <Button label="Mark handled" variant="ghost" onPress={() => void run('lead_handled', {}, 'Marked handled.')} /> : null}
      {mine ? <Button label="Give it back to the pool" variant="ghost" onPress={() => void run('lead_unclaim', {}, 'Back in the pool.')} /> : null}

      {l.contacts.length || l.calls.length ? <H2>History</H2> : null}
      {[...l.contacts.map((c) => ({ at: c.at, text: `${c.channel}${c.note ? `: ${c.note}` : ''} · ${c.by}` })), ...l.calls.map((c) => ({ at: c.at, text: `${c.direction} ${c.kind}${c.missed ? ' (missed)' : ''}${c.text ? `: ${c.text}` : ''}` }))]
        .sort((a, b) => b.at.localeCompare(a.at)).slice(0, 30).map((h, i) => <Pair key={i} k={when(h.at)} v={h.text} />)}
    </Screen>
  );
}
