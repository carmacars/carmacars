import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Image, Modal, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { WebView } from 'react-native-webview';
import { useApp } from '@/app-state';
import { color, space, type } from '@/theme';
import { Button, Small } from '@/ui/kit';

/** A thin black bar under the header while the server cannot be reached; screens keep showing what they last loaded. */
export function OfflineBanner() {
  const { online, ready } = useApp();
  if (online || !ready) return null;
  return (
    <View accessibilityRole="alert" accessibilityLiveRegion="polite" style={s.offline} testID="offline-banner">
      <Text style={{ color: color.white, fontWeight: '700', fontSize: 13 }}>No connection. Showing what was loaded; changes wait until you are back online.</Text>
    </View>
  );
}

/** The app lock: nothing of the account shows until Face ID, the fingerprint or the passcode opens it. */
export function LockScreen() {
  const { locked, unlock, signOut } = useApp();
  const insets = useSafeAreaInsets();
  const asked = useRef(false);
  useEffect(() => { if (locked && !asked.current) { asked.current = true; void unlock(); } if (!locked) asked.current = false; }, [locked, unlock]);
  if (!locked) return null;
  return (
    <View style={[StyleSheet.absoluteFill, s.lock, { paddingTop: insets.top + space.xxl, paddingBottom: insets.bottom + space.xl }]} accessibilityViewIsModal testID="lock-screen">
      <Image source={require('../../assets/splash-mark.png')} style={{ width: 160, height: 160 }} resizeMode="contain" accessibilityLabel="CarmaCars" />
      <Text style={[type.h2, { color: color.white, textAlign: 'center' }]}>CarmaCars is locked</Text>
      <View style={{ alignSelf: 'stretch', paddingHorizontal: space.xl }}>
        <Button label="Unlock" onPress={() => void unlock()} testID="unlock" />
        <Button label="Sign out instead" variant="ghost" onPress={() => void signOut()} style={{ backgroundColor: 'transparent' }} />
        <Small style={{ color: '#BBBBBB', textAlign: 'center' }}>Signing out forgets this phone's session.</Small>
      </View>
    </View>
  );
}

const FAKE_TOKEN = 'XXXX.DUMMY.TOKEN.XXXX';
/**
 * The site's bot check (Cloudflare Turnstile) for the two things a signed-out phone can send: a sign-in code by text and
 * a request to book. The check itself is the site's own page (/app-check) in a small sheet, usually invisible and done
 * in a second; its token goes with the request and the server verifies it exactly as it does for the website.
 */
export function useBotCheck(): { ask: () => Promise<string | null>; sheet: ReactNode } {
  const { config } = useApp();
  const [open, setOpen] = useState(false);
  const done = useRef<((t: string | null) => void) | null>(null);
  const finish = (t: string | null) => { setOpen(false); done.current?.(t); done.current = null; };
  const ask = async (): Promise<string | null> => {
    if (!config || config.turnstile === 'off') return '';
    if (config.turnstile === 'fake') return FAKE_TOKEN;
    return new Promise((resolve) => { done.current = resolve; setOpen(true); });
  };
  const sheet = (
    <Modal visible={open} transparent animationType="fade" onRequestClose={() => finish(null)}>
      <View style={s.sheetBack}>
        <View style={s.sheet}>
          <Text style={type.h3}>Checking it is you, not a bot</Text>
          <Small style={{ marginBottom: space.sm }}>This takes a moment.</Small>
          {open && config ? (
            <WebView source={{ uri: `${config.site_url}/app-check` }} style={{ height: 120, backgroundColor: 'transparent' }} originWhitelist={['https://*']} incognito
              onMessage={(e) => { try { const m = JSON.parse(e.nativeEvent.data) as { type?: string; token?: string }; if (m.type === 'turnstile' && m.token) finish(m.token); } catch { /* not ours */ } }}
              onError={() => finish(null)} />
          ) : null}
          <Button label="Cancel" variant="ghost" onPress={() => finish(null)} />
        </View>
      </View>
    </Modal>
  );
  return { ask, sheet };
}
export const BOT_CHECK_FAILED = 'The security check did not finish. Check your connection and try again.';

const s = StyleSheet.create({
  offline: { backgroundColor: color.black, paddingVertical: 8, paddingHorizontal: space.lg },
  lock: { backgroundColor: color.black, alignItems: 'center', justifyContent: 'space-between', zIndex: 100 },
  sheetBack: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
  sheet: { backgroundColor: color.white, borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: space.lg, paddingBottom: space.xxl }
});
