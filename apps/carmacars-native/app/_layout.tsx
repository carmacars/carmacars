import { useEffect, useRef } from 'react';
import { Stack, useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import * as SplashScreen from 'expo-splash-screen';
import * as Linking from 'expo-linking';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { AppProvider, useApp } from '@/app-state';
import { homeTab } from '@/logic/roles';
import { color } from '@/theme';
import { LockScreen, OfflineBanner } from '@/ui/shell';

// The root of the app: the shared state, the black header of every screen, the offline bar and the app lock. Links from
// outside (universal links and app links to carmacars.ca, carmacars://) are turned into screens by app/+native-intent.tsx;
// a tapped alert is opened by the push listener (src/push).
void SplashScreen.preventAutoHideAsync().catch(() => undefined);

function Shell() {
  const { ready, me } = useApp();
  const router = useRouter();
  const started = useRef(false);
  useEffect(() => {
    if (!ready || started.current) return;
    started.current = true;
    void SplashScreen.hideAsync().catch(() => undefined);
    // staff open on their work, owners on their cars; a link that opened the app wins (app/+native-intent.tsx took it there)
    void Linking.getInitialURL().then((url) => {
      if (url && !/^carmacars:\/\/\/?$/.test(url) && !url.startsWith('exp')) return;
      const tab = homeTab(me?.roles ?? null);
      if (tab !== 'explore') router.replace(`/${tab}` as never);
    });
  }, [ready, me, router]);
  return (
    <>
      <StatusBar style="light" />
      <Stack screenOptions={{ headerStyle: { backgroundColor: color.black }, headerTintColor: color.white, headerTitleStyle: { fontWeight: '700' }, headerBackButtonDisplayMode: 'minimal',
        contentStyle: { backgroundColor: color.white }, animation: 'default' }}>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="sign-in" options={{ title: 'Sign in', presentation: 'modal' }} />
        <Stack.Screen name="two-step" options={{ title: 'Two-step sign-in', presentation: 'modal' }} />
      </Stack>
      <OfflineBanner />
      <LockScreen />
    </>
  );
}

export default function Root() {
  return (
    <SafeAreaProvider>
      <AppProvider>
        <Shell />
      </AppProvider>
    </SafeAreaProvider>
  );
}
