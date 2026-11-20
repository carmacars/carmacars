import { useEffect, useRef, useState, type ReactNode } from 'react';
import { AccessibilityInfo, ActivityIndicator, Animated, Platform, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, View, type StyleProp, type TextInputProps, type TextStyle, type ViewStyle } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import * as Haptics from 'expo-haptics';
import { color, motion, radius, space, TOUCH, type } from '@/theme';

// The app's own controls: plain native views in the brand's red, black and white. Every control is at least 48 high,
// carries its role and state for VoiceOver and TalkBack, and moves only when the phone allows motion.

/** True when the phone asks for reduced motion (Settings > Accessibility). */
export function useReducedMotion(): boolean {
  const [reduce, setReduce] = useState(false);
  useEffect(() => {
    let live = true;
    void AccessibilityInfo.isReduceMotionEnabled().then((v) => { if (live) setReduce(v); });
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduce);
    return () => { live = false; sub.remove(); };
  }, []);
  return reduce;
}

/** Content that arrives with a short fade and a small rise; with Reduce Motion it is simply there. */
export function Appear({ children, delay = 0, style }: { children: ReactNode; delay?: number; style?: StyleProp<ViewStyle> }) {
  const reduce = useReducedMotion();
  const v = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (reduce) { v.setValue(1); return; }
    const a = Animated.timing(v, { toValue: 1, duration: motion.base, delay, useNativeDriver: true });
    a.start();
    return () => a.stop();
  }, [reduce, delay, v]);
  return <Animated.View style={[style, { opacity: v, transform: [{ translateY: v.interpolate({ inputRange: [0, 1], outputRange: [reduce ? 0 : motion.rise, 0] }) }] }]}>{children}</Animated.View>;
}

export function Screen({ children, onRefresh, refreshing = false, footer, padded = true, testID }: { children: ReactNode; onRefresh?: () => void; refreshing?: boolean; footer?: ReactNode; padded?: boolean; testID?: string }) {
  return (
    <SafeAreaView style={s.screen} edges={['left', 'right', 'bottom']} testID={testID}>
      <ScrollView contentContainerStyle={[padded && s.pad, { flexGrow: 1 }]} keyboardShouldPersistTaps="handled" contentInsetAdjustmentBehavior="automatic"
        refreshControl={onRefresh ? <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={color.red} colors={[color.red]} /> : undefined}>
        {children}
      </ScrollView>
      {footer ? <View style={s.footer}>{footer}</View> : null}
    </SafeAreaView>
  );
}

export const H1 = ({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) => <Text accessibilityRole="header" style={[type.h1, { marginBottom: space.sm }, style]}>{children}</Text>;
export const H2 = ({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) => <Text accessibilityRole="header" style={[type.h2, { marginTop: space.lg, marginBottom: space.sm }, style]}>{children}</Text>;
export const H3 = ({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) => <Text style={[type.h3, style]}>{children}</Text>;
export const P = ({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) => <Text style={[type.body, { marginBottom: space.sm }, style]}>{children}</Text>;
export const Small = ({ children, style }: { children: ReactNode; style?: StyleProp<TextStyle> }) => <Text style={[type.small, style]}>{children}</Text>;

type Variant = 'primary' | 'dark' | 'outline' | 'ghost' | 'danger';
export function Button({ label, onPress, variant = 'primary', busy = false, disabled = false, hint, testID, style }: { label: string; onPress: () => void; variant?: Variant; busy?: boolean; disabled?: boolean; hint?: string; testID?: string; style?: StyleProp<ViewStyle> }) {
  const off = disabled || busy;
  const fill = variant === 'primary' ? color.red : variant === 'dark' ? color.black : 'transparent';
  const text = variant === 'primary' || variant === 'dark' ? color.white : variant === 'danger' ? color.red : color.ink;
  return (
    <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={label} accessibilityHint={hint} accessibilityState={{ disabled: off, busy }} disabled={off}
      onPress={() => { if (Platform.OS !== 'web') void Haptics.selectionAsync().catch(() => undefined); onPress(); }}
      style={({ pressed }) => [s.button, { backgroundColor: pressed && variant === 'primary' ? color.redPressed : fill, opacity: off ? 0.5 : pressed ? 0.9 : 1 },
        (variant === 'outline' || variant === 'danger') && { borderWidth: 1.5, borderColor: variant === 'danger' ? color.red : color.ink }, style]}>
      {busy ? <ActivityIndicator color={text} /> : <Text style={[type.button, { color: text }]} numberOfLines={1}>{label}</Text>}
    </Pressable>
  );
}

export function Field({ label, error, help, ...input }: { label: string; error?: string | null; help?: string } & TextInputProps) {
  const [focus, setFocus] = useState(false);
  return (
    <View style={{ marginBottom: space.md }}>
      <Text style={[type.label, { marginBottom: space.xs }]}>{label}</Text>
      <TextInput accessibilityLabel={label} accessibilityHint={error ?? help} placeholderTextColor={color.muted} {...input}
        onFocus={(e) => { setFocus(true); input.onFocus?.(e); }} onBlur={(e) => { setFocus(false); input.onBlur?.(e); }}
        style={[s.input, focus && { borderColor: color.ink }, !!error && { borderColor: color.red }, input.multiline && { minHeight: 96, textAlignVertical: 'top', paddingTop: space.md }, input.style]} />
      {error ? <Text accessibilityLiveRegion="polite" style={[type.small, { color: color.red, marginTop: space.xs }]}>{error}</Text> : help ? <Text style={[type.small, { marginTop: space.xs }]}>{help}</Text> : null}
    </View>
  );
}

export function Card({ children, onPress, style, label, testID }: { children: ReactNode; onPress?: () => void; style?: StyleProp<ViewStyle>; label?: string; testID?: string }) {
  if (!onPress) return <View style={[s.card, style]} testID={testID}>{children}</View>;
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={label} onPress={onPress} style={({ pressed }) => [s.card, pressed && { backgroundColor: color.field }, style]}>{children}</Pressable>;
}

export function Notice({ tone = 'info', children, title }: { tone?: 'info' | 'ok' | 'warn' | 'bad'; children?: ReactNode; title?: string }) {
  const bg = tone === 'ok' ? color.okSoft : tone === 'warn' ? color.warnSoft : tone === 'bad' ? color.redSoft : color.field;
  const fg = tone === 'ok' ? color.ok : tone === 'warn' ? color.warn : tone === 'bad' ? color.red : color.ink;
  return (
    <View accessibilityRole={tone === 'bad' ? 'alert' : undefined} accessibilityLiveRegion={tone === 'bad' ? 'assertive' : 'polite'} style={[s.notice, { backgroundColor: bg }]}>
      {title ? <Text style={[type.h3, { color: fg, marginBottom: children ? 2 : 0 }]}>{title}</Text> : null}
      {typeof children === 'string' ? <Text style={[type.body, { color: fg }]}>{children}</Text> : children}
    </View>
  );
}

export function Chip({ label, on, onPress, testID }: { label: string; on: boolean; onPress: () => void; testID?: string }) {
  return (
    <Pressable testID={testID} accessibilityRole="button" accessibilityState={{ selected: on }} accessibilityLabel={label} onPress={onPress} hitSlop={6}
      style={[s.chip, on && { backgroundColor: color.black, borderColor: color.black }]}>
      <Text style={[type.label, { color: on ? color.white : color.ink }]}>{label}</Text>
    </Pressable>
  );
}
export function Check({ label, on, onChange, error, testID }: { label: string; on: boolean; onChange: (v: boolean) => void; error?: string | null; testID?: string }) {
  return (
    <Pressable testID={testID} accessibilityRole="checkbox" accessibilityState={{ checked: on }} accessibilityLabel={label} onPress={() => onChange(!on)} style={s.check}>
      <View style={[s.box, on && { backgroundColor: color.red, borderColor: color.red }, !!error && { borderColor: color.red }]}>{on ? <Text style={{ color: color.white, fontWeight: '800' }}>✓</Text> : null}</View>
      <View style={{ flex: 1 }}>
        <Text style={type.body}>{label}</Text>
        {error ? <Text style={[type.small, { color: color.red }]}>{error}</Text> : null}
      </View>
    </Pressable>
  );
}
export const Row = ({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) => <View style={[{ flexDirection: 'row', alignItems: 'center', gap: space.sm }, style]}>{children}</View>;
export const Wrap = ({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) => <View style={[{ flexDirection: 'row', flexWrap: 'wrap', gap: space.sm }, style]}>{children}</View>;
export const Line = () => <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: color.line, marginVertical: space.md }} />;
export const Pair = ({ k, v, strong }: { k: string; v: string; strong?: boolean }) => (
  <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: space.md, paddingVertical: 5 }}>
    <Text style={[type.body, { color: color.muted, flexShrink: 1 }]}>{k}</Text>
    <Text style={[type.body, { color: color.ink, fontWeight: strong ? '800' : '500', textAlign: 'right', flexShrink: 1 }]}>{v}</Text>
  </View>
);
export const Badge = ({ label, tone = 'dark' }: { label: string; tone?: 'dark' | 'red' | 'ok' | 'muted' }) => (
  <View style={[s.badge, { backgroundColor: tone === 'red' ? color.red : tone === 'ok' ? color.ok : tone === 'muted' ? color.line : color.black }]}>
    <Text style={{ fontSize: 12, fontWeight: '700', color: tone === 'muted' ? color.ink : color.white }}>{label}</Text>
  </View>
);
export const Busy = ({ label = 'Loading' }: { label?: string }) => <View accessibilityLabel={label} style={{ padding: space.xxl, alignItems: 'center' }}><ActivityIndicator color={color.red} size="large" /></View>;
export function Empty({ title, body, action }: { title: string; body?: string; action?: ReactNode }) {
  return <View style={{ alignItems: 'center', padding: space.xl, gap: space.sm }}><Text style={[type.h2, { textAlign: 'center' }]}>{title}</Text>{body ? <Text style={[type.body, { textAlign: 'center', color: color.muted }]}>{body}</Text> : null}{action}</View>;
}
/** A list that failed to load: the server's sentence and Try again (the offline banner says when there is no connection). */
export function Failed({ message, onRetry }: { message: string; onRetry: () => void }) {
  return <View style={{ padding: space.lg }}><Notice tone="bad">{message}</Notice><Button label="Try again" variant="outline" onPress={onRetry} /></View>;
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: color.white },
  pad: { padding: space.lg, paddingBottom: space.xxl },
  footer: { padding: space.lg, paddingTop: space.md, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: color.line, backgroundColor: color.white },
  button: { minHeight: TOUCH + 4, borderRadius: radius.md, alignItems: 'center', justifyContent: 'center', paddingHorizontal: space.lg, marginBottom: space.sm },
  input: { minHeight: TOUCH + 2, borderRadius: radius.md, borderWidth: 1.5, borderColor: color.line, backgroundColor: color.field, paddingHorizontal: space.md, fontSize: 16, color: color.ink },
  card: { borderRadius: radius.lg, borderWidth: 1, borderColor: color.line, backgroundColor: color.white, padding: space.lg, marginBottom: space.md },
  notice: { borderRadius: radius.md, padding: space.md, marginBottom: space.md },
  chip: { minHeight: 40, paddingHorizontal: space.md, borderRadius: radius.pill, borderWidth: 1.5, borderColor: color.line, alignItems: 'center', justifyContent: 'center', backgroundColor: color.white },
  check: { flexDirection: 'row', gap: space.md, alignItems: 'flex-start', minHeight: TOUCH, paddingVertical: space.sm },
  box: { width: 26, height: 26, borderRadius: 7, borderWidth: 2, borderColor: color.muted, alignItems: 'center', justifyContent: 'center', marginTop: 1 },
  badge: { alignSelf: 'flex-start', paddingHorizontal: 9, paddingVertical: 3, borderRadius: radius.pill }
});
