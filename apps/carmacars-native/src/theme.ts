// CarmaCars: red, black and white. One place for every colour, size and space in the app.
export const color = {
  red: '#D0111B', redPressed: '#A80D15', redSoft: '#FDECED',
  black: '#0A0A0A', ink: '#111111', body: '#2B2B2B', muted: '#6B6B6B', line: '#E4E4E4', field: '#F6F6F6', white: '#FFFFFF',
  ok: '#0B7A3B', okSoft: '#E8F5EC', warn: '#8A5A00', warnSoft: '#FFF4DB'
} as const;
export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const;
export const radius = { sm: 8, md: 12, lg: 18, pill: 999 } as const;
export const type = {
  h1: { fontSize: 28, lineHeight: 34, fontWeight: '800' as const, letterSpacing: -0.4, color: color.ink },
  h2: { fontSize: 20, lineHeight: 26, fontWeight: '700' as const, color: color.ink },
  h3: { fontSize: 16, lineHeight: 22, fontWeight: '700' as const, color: color.ink },
  body: { fontSize: 16, lineHeight: 23, color: color.body },
  small: { fontSize: 13, lineHeight: 18, color: color.muted },
  label: { fontSize: 13, lineHeight: 18, fontWeight: '600' as const, color: color.ink },
  button: { fontSize: 16, lineHeight: 20, fontWeight: '700' as const }
} as const;
/** Motion is short and small; with Reduce Motion on in the phone's settings nothing moves (src/ui/kit.tsx). */
export const motion = { fast: 140, base: 220, rise: 8 } as const;
/** The smallest touch target (Apple: 44 pt, Android: 48 dp). */
export const TOUCH = 48;
