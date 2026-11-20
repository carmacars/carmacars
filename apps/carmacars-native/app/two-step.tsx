import { useState } from 'react';
import { useRouter } from 'expo-router';
import { useApp, useAct } from '@/app-state';
import { Button, Field, H1, Notice, P, Screen } from '@/ui/kit';

// Staff accounts with two-step sign-in: the 6-digit code of the authenticator app, as on the website. The session that
// comes back carries the second factor; until then the database refuses every staff read.
export default function TwoStep() {
  const { api, signedIn, signOut } = useApp();
  const router = useRouter();
  const { busy, error, act } = useAct();
  const [code, setCode] = useState('');
  const go = async () => {
    const r = await act('code', () => api.call('auth.twoStep', { body: { code } }));
    if (r.ok) { await signedIn(r.data); router.replace('/'); }
  };
  return (
    <Screen testID="two-step">
      <H1>Two-step sign-in</H1>
      <P>Open your authenticator app and enter the 6-digit code for CarmaCars.</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      <Field label="Code" value={code} onChangeText={setCode} keyboardType="number-pad" textContentType="oneTimeCode" autoComplete="one-time-code" maxLength={7} returnKeyType="go" onSubmitEditing={() => void go()} autoFocus />
      <Button label="Continue" onPress={() => void go()} busy={busy === 'code'} disabled={code.replace(/\D/g, '').length !== 6} />
      <Button label="Sign out" variant="ghost" onPress={() => { void signOut().then(() => router.replace('/')); }} />
    </Screen>
  );
}
