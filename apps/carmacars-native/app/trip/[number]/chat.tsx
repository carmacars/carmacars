import { useEffect, useRef, useState } from 'react';
import { FlatList, KeyboardAvoidingView, Platform, StyleSheet, Text, TextInput, View } from 'react-native';
import { Stack, useLocalSearchParams } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useAct, useApp, useLoad } from '@/app-state';
import { when } from '@/logic/format';
import { color, radius, space, type } from '@/theme';
import { Busy, Button, Empty, Failed, Notice } from '@/ui/kit';
import { loadTrip, type TripData } from '@/trip-data';

// The trip's messages with the CarmaCars team: the same thread as on the booking's page. New messages are read every
// 20 seconds while the screen is open, and arrive as alerts when it is not.
export default function Chat() {
  const { number } = useLocalSearchParams<{ number: string }>();
  const { api, online } = useApp();
  const trip = useLoad<TripData>(`trip:${number}`, () => loadTrip(api, number));
  const { busy, error, act } = useAct();
  const [text, setText] = useState('');
  const list = useRef<FlatList>(null);
  useEffect(() => { const t = setInterval(() => trip.reload(), 20_000); return () => clearInterval(t); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const send = async () => {
    const body = text.trim();
    if (body.length < 2) return;
    const r = await act('send', () => api.call('trip.message', { params: { number }, body: { body } }));
    if (r.ok) { setText(''); trip.reload(); }
  };
  if (trip.loading) return <Busy />;
  if (!trip.data) return <Failed message={trip.error ?? 'The messages could not be loaded.'} onRetry={trip.reload} />;
  const msgs = trip.data.messages;
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.white }} edges={['bottom', 'left', 'right']}>
      <Stack.Screen options={{ title: `Messages · ${number}` }} />
      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined} keyboardVerticalOffset={90}>
        <FlatList ref={list} data={msgs} keyExtractor={(m) => m.id} contentContainerStyle={{ padding: space.lg, gap: space.sm, flexGrow: 1 }} onContentSizeChange={() => list.current?.scrollToEnd({ animated: false })}
          ListEmptyComponent={<Empty title="No messages yet" body="Ask us anything about this trip. We answer here and by alert." />}
          renderItem={({ item }) => {
            const mine = item.direction === 'inbound';
            return (
              <View style={[s.bubble, mine ? s.mine : s.theirs]} accessible accessibilityLabel={`${mine ? 'You' : item.from}, ${when(item.at)}: ${item.body}`}>
                <Text style={[type.body, { color: mine ? color.white : color.ink, marginBottom: 2 }]}>{item.body}</Text>
                <Text style={{ fontSize: 11, color: mine ? '#F3C6C9' : color.muted }}>{mine ? 'You' : item.from} · {when(item.at)}</Text>
              </View>
            );
          }} />
        {error ? <View style={{ paddingHorizontal: space.lg }}><Notice tone="bad">{error}</Notice></View> : null}
        <View style={s.bar}>
          <TextInput value={text} onChangeText={setText} placeholder={online ? 'Write a message' : 'No connection'} placeholderTextColor={color.muted} multiline maxLength={4000} accessibilityLabel="Your message" style={s.input} editable={online} testID="message" />
          <Button label="Send" onPress={() => void send()} busy={busy === 'send'} disabled={text.trim().length < 2 || !online} style={{ marginBottom: 0, minWidth: 84 }} testID="send" />
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
const s = StyleSheet.create({
  bubble: { maxWidth: '84%', padding: space.md, borderRadius: radius.lg },
  mine: { alignSelf: 'flex-end', backgroundColor: color.red, borderBottomRightRadius: 4 },
  theirs: { alignSelf: 'flex-start', backgroundColor: color.field, borderBottomLeftRadius: 4 },
  bar: { flexDirection: 'row', alignItems: 'flex-end', gap: space.sm, padding: space.md, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: color.line },
  input: { flex: 1, minHeight: 50, maxHeight: 130, borderRadius: radius.md, borderWidth: 1.5, borderColor: color.line, backgroundColor: color.field, paddingHorizontal: space.md, paddingTop: 13, fontSize: 16, color: color.ink }
});
