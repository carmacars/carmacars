import { useState } from 'react';
import { View } from 'react-native';
import { useRouter } from 'expo-router';
import { useApp, useAct } from '@/app-state';
import { passkeysSupported, usePasskey } from '@/native';
import { openSite } from '@/native';
import { space } from '@/theme';
import { Button, Field, H1, Line, Notice, P, Screen, Small } from '@/ui/kit';
import { BOT_CHECK_FAILED, useBotCheck } from '@/ui/shell';

// Sign in with the same account as the website: email and password, a texted code, or a passkey. Staff whose account
// asks for two-step sign-in go on to the code of their authenticator app.
export default function SignIn() {
  const { api, signedIn, reloadMe, config } = useApp();
  const router = useRouter();
  const { busy, error, fieldErrors, act, setError } = useAct();
  const bot = useBotCheck();
  const [mode, setMode] = useState<'email' | 'phone' | 'code'>('email');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [phone, setPhone] = useState('');
  const [sentTo, setSentTo] = useState<{ phone: string; display: string } | null>(null);
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [needsName, setNeedsName] = useState(false);

  const done = async (s: Parameters<typeof signedIn>[0]) => {
    const me = await signedIn(s);
    if (me?.needs_two_step) router.replace('/two-step');
    else if (router.canGoBack()) router.back(); else router.replace('/');
  };
  const withEmail = async () => {
    const r = await act('email', () => api.call('auth.signIn', { body: { email, password } }));
    if (r.ok) await done(r.data);
  };
  const withPasskey = async () => {
    setError(null);
    const o = await act('passkey', () => api.call('auth.passkeyOptions'));
    if (!o.ok) return;
    const a = await usePasskey(o.data);
    if (!a.ok) { if (a.reason !== 'cancelled') setError(a.reason === 'none' ? 'There is no CarmaCars passkey on this phone yet. Sign in another way, then add one in Profile.' : 'The passkey did not work. Sign in another way.'); return; }
    const r = await act('passkey', () => api.call('auth.passkeyVerify', { body: { challenge_id: o.data.challenge_id, credential: a.credential } }));
    if (r.ok) await done(r.data);
  };
  const sendCode = async () => {
    const token = await bot.ask();
    if (token === null) { setError(BOT_CHECK_FAILED); return; }
    const r = await act('send', () => api.call('auth.phoneStart', { body: { phone, turnstile: token || undefined } }));
    if (r.ok) { setSentTo(r.data); setMode('code'); }
  };
  const checkCode = async () => {
    const r = await act('code', () => api.call('auth.phoneVerify', { body: { phone: sentTo?.phone ?? phone, code, name: name.trim() || undefined } }));
    if (!r.ok) return;
    // a new account made by this number: its name, once
    if (r.data.needs_name && !name.trim()) { await api.adopt(r.data); setNeedsName(true); return; }
    await done(r.data);
  };
  const saveName = async () => {
    const r = await act('name', () => api.call('me.name', { body: { name } }));
    if (!r.ok) return;
    await reloadMe();
    if (router.canGoBack()) router.back(); else router.replace('/');
  };

  return (
    <Screen testID="sign-in">
      {bot.sheet}
      <H1>Sign in</H1>
      <P>Use your CarmaCars account: the same one as on carmacars.ca.</P>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {needsName ? (
        <View>
          <Field label="Your full name" value={name} onChangeText={setName} autoCapitalize="words" autoComplete="name" textContentType="name" returnKeyType="done" onSubmitEditing={() => void saveName()} />
          <Button label="Continue" onPress={() => void saveName()} busy={busy === 'name'} disabled={name.trim().length < 2} />
        </View>
      ) : mode === 'email' ? (
        <View>
          <Field label="Email" value={email} onChangeText={setEmail} error={fieldErrors.email} keyboardType="email-address" autoCapitalize="none" autoCorrect={false} autoComplete="email" textContentType="username" testID="email" />
          <Field label="Password" value={password} onChangeText={setPassword} error={fieldErrors.password} secureTextEntry autoComplete="current-password" textContentType="password" returnKeyType="go" onSubmitEditing={() => void withEmail()} testID="password" />
          <Button label="Sign in" onPress={() => void withEmail()} busy={busy === 'email'} disabled={!email.trim() || !password} testID="submit" />
          <Button label="Forgot your password?" variant="ghost" onPress={() => void openSite('/reset-password', config?.site_url)} />
        </View>
      ) : mode === 'phone' ? (
        <View>
          <Field label="Mobile number" value={phone} onChangeText={setPhone} error={fieldErrors.phone} keyboardType="phone-pad" autoComplete="tel" textContentType="telephoneNumber" help="We text a 6-digit code. A new number makes a new account." />
          <Button label="Text me a code" onPress={() => void sendCode()} busy={busy === 'send'} disabled={phone.replace(/\D/g, '').length < 10} />
        </View>
      ) : (
        <View>
          <P>We texted a code to {sentTo?.display ?? phone}.</P>
          <Field label="Code" value={code} onChangeText={setCode} error={fieldErrors.code} keyboardType="number-pad" autoComplete="sms-otp" textContentType="oneTimeCode" maxLength={8} returnKeyType="go" onSubmitEditing={() => void checkCode()} />
          <Button label="Sign in" onPress={() => void checkCode()} busy={busy === 'code'} disabled={code.replace(/\D/g, '').length < 4} />
          <Button label="Use another number" variant="ghost" onPress={() => { setMode('phone'); setCode(''); }} />
        </View>
      )}
      {!needsName ? (
        <View style={{ marginTop: space.md }}>
          <Line />
          {passkeysSupported() ? <Button label="Sign in with a passkey" variant="dark" onPress={() => void withPasskey()} busy={busy === 'passkey'} testID="passkey" /> : null}
          {mode === 'email' && config?.phone_sign_in.enabled !== false ? <Button label="Sign in with your phone number" variant="outline" onPress={() => { setMode('phone'); setError(null); }} /> : null}
          {mode !== 'email' ? <Button label="Sign in with email" variant="outline" onPress={() => { setMode('email'); setError(null); }} /> : null}
          <Small style={{ textAlign: 'center', marginTop: space.sm }}>New here? Sign in with your phone number to make an account, or create one with your email on carmacars.ca.</Small>
          <Button label="Create an account with email" variant="ghost" onPress={() => void openSite('/create-account', config?.site_url)} />
        </View>
      ) : null}
    </Screen>
  );
}
