import { useState } from 'react';
import { Alert } from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { useAct, useApp } from '@/app-state';
import { when } from '@/logic/format';
import { Button, Field, H1, Notice, P, Screen, Small } from '@/ui/kit';

// Delete my account, started here in the app (the same request as on the site, migration 0390): the account and its
// personal data are removed by an Admin within 30 days, except what the law makes a rental company keep (signed
// agreements, invoices and payment records). Until it is done the request can be withdrawn.
export default function DeleteAccount() {
  const { api, me, reloadMe } = useApp();
  const router = useRouter();
  const { busy, error, act } = useAct();
  const [reason, setReason] = useState('');
  const d = me?.deletion ?? null;
  const open = d?.request?.status === 'open';
  const ask = () => Alert.alert('Delete your account?', 'Your sign-in, profile, documents and saved cards are removed. Trips that are booked or underway must be finished or cancelled first.', [
    { text: 'Keep my account', style: 'cancel' },
    { text: 'Delete my account', style: 'destructive', onPress: () => { void act('ask', () => api.call('me.deletionAsk', { body: { reason: reason.trim() || undefined } })).then((r) => { if (r.ok) void reloadMe(); }); } }]);
  const withdraw = async () => { const r = await act('withdraw', () => api.call('me.deletionWithdraw')); if (r.ok) void reloadMe(); };
  return (
    <Screen testID="delete-account">
      <Stack.Screen options={{ title: 'Delete my account' }} />
      <H1>Delete my account</H1>
      {error ? <Notice tone="bad">{error}</Notice> : null}
      {d && !d.allowed ? <Notice tone="warn">A staff account is closed by an Admin, not from the app. Ask your manager, or write to us from Contact us.</Notice> : open ? (<>
        <Notice tone="ok" title="Your request is in">We delete the account within 30 days and email you when it is done. Asked {when(d!.request!.requested_at)}.</Notice>
        <Button label="Keep my account after all" variant="outline" onPress={() => void withdraw()} busy={busy === 'withdraw'} testID="withdraw" />
      </>) : d?.request?.status === 'done' ? <Notice tone="ok">Your account has been deleted.</Notice> : (<>
        <P>We remove your sign-in, your profile, your licence photos and your saved cards within 30 days.</P>
        <P>The law makes us keep signed rental agreements, invoices and payment records for a set time; they are kept without your sign-in and removed when that time ends.</P>
        <Field label="Why are you leaving? (optional)" value={reason} onChangeText={setReason} multiline maxLength={500} />
        <Button label="Delete my account" variant="danger" onPress={ask} busy={busy === 'ask'} testID="confirm-delete" />
        <Small>You can change your mind until the deletion is done.</Small>
      </>)}
      <Button label="Back" variant="ghost" onPress={() => router.back()} />
    </Screen>
  );
}
