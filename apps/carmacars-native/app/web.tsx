import { useEffect } from 'react';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useApp } from '@/app-state';
import { sitePath } from '@/logic/links';
import { openSite } from '@/native';
import { Button, Empty, Screen } from '@/ui/kit';

// A page of the site the app has no screen for (the Admin portal's long tail, a pay link, a guide): it opens in the
// browser inside the app, and this screen is what is behind it when the browser is closed.
export default function WebPage() {
  const { path } = useLocalSearchParams<{ path?: string }>();
  const { config, ready } = useApp();
  const router = useRouter();
  // only a path of the site, whatever the link said
  const safe = sitePath(typeof path === 'string' ? path : null);
  useEffect(() => { if (ready && safe) void openSite(safe, config?.site_url); }, [ready, safe, config?.site_url]);
  return (
    <Screen>
      <Stack.Screen options={{ title: 'carmacars.ca' }} />
      <Empty title={safe ? 'This page opens on carmacars.ca' : 'This link does not open here'} body={safe ? 'It is open in the browser inside the app.' : undefined}
        action={<>{safe ? <Button label="Open it again" variant="outline" onPress={() => void openSite(safe, config?.site_url)} /> : null}<Button label="Back to the app" onPress={() => router.replace('/')} /></>} />
    </Screen>
  );
}
