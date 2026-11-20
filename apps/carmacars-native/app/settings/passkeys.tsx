import { Alert, Text, View } from 'react-native';
import { Stack } from 'expo-router';
import { useAct, useApp, useLoad } from '@/app-state';
import { deviceLabel, makePasskey, passkeysSupported } from '@/native';
import { when } from '@/logic/format';
import type { PasskeyRow } from '@/shared';
import { type } from '@/theme';
import { Busy, Button, Card, Empty, Failed, Notice, P, Row, Screen, Small } from '@/ui/kit';

// Passkeys: sign in with Face ID, a fingerprint or the screen lock instead of a password. The key stays on the phone
// (and in its password manager); the site keeps only its public half.
export default function Passkeys() {
  const { api } = useApp();
  const list = useLoad<PasskeyRow[]>('me.passkeys', () => api.call('me.passkeys'));
  const { busy, error, act, setError } = useAct();
  const add = async () => {
    const o = await act('add', () => api.call('me.passkeyOptions'));
    if (!o.ok) return;
    const made = await makePasskey(o.data);
    if (!made.ok) { if (made.reason !== 'cancelled') setError('The phone could not make a passkey. Check that a screen lock and a password manager are set up, then try again.'); return; }
    const r = await act('add', () => api.call('me.passkeyAdd', { body: { challenge_id: o.data.challenge_id, credential: made.credential, device: deviceLabel() } }));
    if (r.ok) list.reload();
  };
  const remove = (k: PasskeyRow) => Alert.alert('Remove this passkey?', 'It will no longer sign in to CarmaCars. Remove it from your phone\'s passwords too.', [{ text: 'Cancel', style: 'cancel' },
    { text: 'Remove', style: 'destructive', onPress: () => { void act(k.id, () => api.call('me.passkeyRemove', { params: { id: k.id } })).then((r) => { if (r.ok) list.reload(); }); } }]);
  return (
    <Screen onRefresh={list.reload} refreshing={list.refreshing} testID="passkeys">
      <Stack.Screen options={{ title: 'Passkeys' }} />
      <P>A passkey signs you in with your face, your fingerprint or your screen lock. Nothing to remember, nothing to type.</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {!passkeysSupported() ? <Notice tone="warn">This phone does not support passkeys.</Notice> : <Button label="Add a passkey on this phone" onPress={() => void add()} busy={busy === 'add'} testID="add-passkey" />}
      {list.loading ? <Busy /> : !list.data ? <Failed message={list.error ?? 'Not loaded.'} onRetry={list.reload} /> : !list.data.length ? <Empty title="No passkeys yet" /> : list.data.map((k) => (
        <Card key={k.id}>
          <Row style={{ justifyContent: 'space-between' }}>
            <View style={{ flex: 1 }}>
              <Text style={type.h3}>{k.device ?? 'Passkey'}</Text>
              <Small>Added {when(k.created_at, false)}{k.last_used_at ? ` · last used ${when(k.last_used_at, false)}` : ''}</Small>
            </View>
            <Button label="Remove" variant="ghost" onPress={() => remove(k)} busy={busy === k.id} style={{ marginBottom: 0 }} />
          </Row>
        </Card>
      ))}
    </Screen>
  );
}
