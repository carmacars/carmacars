import { useRef, useState } from 'react';
import { Modal, PanResponder, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import DateTimePicker, { DateTimePickerAndroid } from '@react-native-community/datetimepicker';
import Svg, { Path } from 'react-native-svg';
import ViewShot from 'react-native-view-shot';
import { color, radius, space, TOUCH, type } from '@/theme';
import { Button, Small } from '@/ui/kit';

// The phone's own date and time pickers, and a signature box drawn with a finger.

const pad = (n: number) => String(n).padStart(2, '0');
const toDay = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const fromDay = (day: string, time = '12:00') => { const [y, m, d] = day.split('-').map(Number); const [hh, mm] = time.split(':').map(Number); return new Date(y!, m! - 1, d!, hh, mm); };

/** A date ("2026-11-20") or a time ("10:00"), chosen with the system picker. The values are wall-clock: the server reads them as Toronto time. */
export function WhenField({ label, mode, value, onChange, min, error, testID }: { label: string; mode: 'date' | 'time'; value: string; onChange: (v: string) => void; min?: string; error?: string | null; testID?: string }) {
  const [open, setOpen] = useState(false);
  const current = mode === 'date' ? (value ? fromDay(value) : min ? fromDay(min) : new Date()) : fromDay('2026-01-01', value || '10:00');
  const shown = !value ? 'Choose' : mode === 'date' ? fromDay(value).toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric' }) : fromDay('2026-01-01', value).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit' });
  const pick = (d?: Date) => { if (d) onChange(mode === 'date' ? toDay(d) : `${pad(d.getHours())}:${pad(d.getMinutes() - (d.getMinutes() % 15))}`); };
  const press = () => {
    if (Platform.OS === 'android') DateTimePickerAndroid.open({ value: current, mode, is24Hour: false, minimumDate: mode === 'date' && min ? fromDay(min) : undefined, minuteInterval: 15, onChange: (e, d) => { if (e.type === 'set') pick(d); } });
    else setOpen(true);
  };
  return (
    <View style={{ flex: 1, marginBottom: space.md }}>
      <Text style={[type.label, { marginBottom: space.xs }]}>{label}</Text>
      <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={`${label}: ${shown}`} onPress={press} style={[s.when, !!error && { borderColor: color.red }]}>
        <Text style={[type.body, { color: value ? color.ink : color.muted }]}>{shown}</Text>
      </Pressable>
      {error ? <Small style={{ color: color.red, marginTop: space.xs }}>{error}</Small> : null}
      {Platform.OS === 'ios' ? (
        <Modal visible={open} transparent animationType="fade" onRequestClose={() => setOpen(false)}>
          <Pressable style={s.back} onPress={() => setOpen(false)} accessibilityLabel="Close" />
          <View style={s.sheet}>
            <DateTimePicker value={current} mode={mode} display={mode === 'date' ? 'inline' : 'spinner'} minuteInterval={15} minimumDate={mode === 'date' && min ? fromDay(min) : undefined} accentColor={color.red} themeVariant="light" onChange={(_, d) => pick(d)} />
            <Button label="Done" onPress={() => setOpen(false)} />
          </View>
        </Modal>
      ) : null}
    </View>
  );
}

type Point = [number, number];
const pathOf = (pts: Point[]) => pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
/** Sign with a finger. `onSigned` gets the signature as a PNG data URL (what the site's signing stores), or null when cleared. */
export function SignaturePad({ label, onSigned, height = 170, as = 'data-url' }: { label: string; onSigned: (png: string | null) => void; height?: number;
  /** data-url: "data:image/png;base64,..." (the signing session's own format). file: the address of a PNG file on the phone, to upload. */ as?: 'data-url' | 'file' }) {
  const [strokes, setStrokes] = useState<Point[][]>([]);
  const live = useRef<Point[]>([]);
  const [, tick] = useState(0);
  const shot = useRef<{ capture?: () => Promise<string> } | null>(null);
  const capture = () => { setTimeout(() => { void shot.current?.capture?.().then((out: string) => onSigned(as === 'file' ? out : `data:image/png;base64,${out}`)).catch(() => onSigned(null)); }, 60); };
  const pan = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true, onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => { live.current = [[e.nativeEvent.locationX, e.nativeEvent.locationY]]; tick((n) => n + 1); },
    onPanResponderMove: (e) => { live.current.push([e.nativeEvent.locationX, e.nativeEvent.locationY]); tick((n) => n + 1); },
    onPanResponderRelease: () => { const done = live.current; live.current = []; if (done.length > 1) { setStrokes((p) => [...p, done]); capture(); } else tick((n) => n + 1); }
  })).current;
  const empty = strokes.length === 0 && live.current.length === 0;
  return (
    <View style={{ marginBottom: space.md }}>
      <Text style={[type.label, { marginBottom: space.xs }]}>{label}</Text>
      <ViewShot ref={shot as never} options={{ format: 'png', result: as === 'file' ? 'tmpfile' : 'base64', quality: 1 }} style={{ backgroundColor: color.white }}>
        <View accessible accessibilityLabel={`${label}. Draw your signature with a finger.`} style={[s.pad, { height }]} {...pan.panHandlers}>
          <Svg width="100%" height="100%">
            {[...strokes, live.current].filter((p) => p.length > 1).map((p, i) => <Path key={i} d={pathOf(p)} stroke={color.black} strokeWidth={2.6} strokeLinecap="round" strokeLinejoin="round" fill="none" />)}
          </Svg>
          {empty ? <Text pointerEvents="none" style={s.hint}>Sign here</Text> : null}
        </View>
      </ViewShot>
      {!empty ? <Button label="Clear" variant="ghost" onPress={() => { setStrokes([]); onSigned(null); }} /> : null}
    </View>
  );
}

const s = StyleSheet.create({
  when: { minHeight: TOUCH + 2, borderRadius: radius.md, borderWidth: 1.5, borderColor: color.line, backgroundColor: color.field, paddingHorizontal: space.md, justifyContent: 'center' },
  back: { flex: 1, backgroundColor: 'rgba(0,0,0,0.45)' },
  sheet: { backgroundColor: color.white, padding: space.lg, paddingBottom: space.xxl, borderTopLeftRadius: 20, borderTopRightRadius: 20 },
  pad: { borderWidth: 1.5, borderColor: color.ink, borderRadius: radius.md, borderStyle: 'dashed', overflow: 'hidden' },
  hint: { position: 'absolute', alignSelf: 'center', top: '42%', color: color.muted, fontSize: 16 }
});
