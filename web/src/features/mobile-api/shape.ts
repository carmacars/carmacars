// A small validator for the mobile API's request bodies (release 48). The website's forms use zod; this file is shared
// with the native app (apps/carmacars-native), whose bundler and tests read it straight from here, so it has no
// imports at all. A shape is a function that returns the cleaned value or throws a ShapeError naming the field.

export class ShapeError extends Error {
  readonly field: string;
  constructor(field: string, message: string) { super(message); this.name = 'ShapeError'; this.field = field; }
}
export type Shape<T> = (v: unknown, field: string) => T;
export type Infer<S> = S extends Shape<infer T> ? T : never;

export const str = (o: { min?: number; max?: number; re?: RegExp; trim?: boolean; what?: string } = {}): Shape<string> => (v, f) => {
  if (typeof v !== 'string') throw new ShapeError(f, `${o.what ?? f} is missing.`);
  const s = o.trim === false ? v : v.trim();
  if (s.length < (o.min ?? 0)) throw new ShapeError(f, `${o.what ?? f} is missing.`);
  if (s.length > (o.max ?? 2000)) throw new ShapeError(f, `${o.what ?? f} is too long.`);
  if (o.re && !o.re.test(s)) throw new ShapeError(f, `Check ${o.what ?? f}.`);
  return s;
};
export const num = (o: { int?: boolean; min?: number; max?: number } = {}): Shape<number> => (v, f) => {
  if (typeof v !== 'number' || !Number.isFinite(v) || (o.int && !Number.isInteger(v)) || v < (o.min ?? -Infinity) || v > (o.max ?? Infinity)) throw new ShapeError(f, `Check ${f}.`);
  return v;
};
export const bool: Shape<boolean> = (v, f) => { if (typeof v !== 'boolean') throw new ShapeError(f, `Check ${f}.`); return v; };
export const oneOf = <const T extends readonly string[]>(...values: T): Shape<T[number]> => (v, f) => {
  if (typeof v !== 'string' || !values.includes(v)) throw new ShapeError(f, `Check ${f}.`);
  return v as T[number];
};
/** Missing, undefined or null: undefined. */
export const opt = <T>(s: Shape<T>): Shape<T | undefined> => (v, f) => (v === undefined || v === null ? undefined : s(v, f));
export const arr = <T>(s: Shape<T>, o: { max?: number } = {}): Shape<T[]> => (v, f) => {
  if (!Array.isArray(v) || v.length > (o.max ?? 100)) throw new ShapeError(f, `Check ${f}.`);
  return v.map((x, i) => s(x, `${f}.${i}`));
};
/** A plain JSON object passed on as it is (the database checks it); only its size is limited here. */
export const bag = (o: { maxBytes?: number } = {}): Shape<Record<string, unknown>> => (v, f) => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new ShapeError(f, `Check ${f}.`);
  if (JSON.stringify(v).length > (o.maxBytes ?? 200_000)) throw new ShapeError(f, `${f} is too large.`);
  return v as Record<string, unknown>;
};
/** An object with these fields; anything else sent is dropped. */
export const obj = <S extends Record<string, Shape<unknown>>>(fields: S): Shape<{ [K in keyof S]: Infer<S[K]> }> => (v, f) => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new ShapeError(f || 'body', 'Send the fields as JSON.');
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(fields)) out[k] = fields[k]!((v as Record<string, unknown>)[k], f ? `${f}.${k}` : k);
  return out as { [K in keyof S]: Infer<S[K]> };
};

export type Parsed<T> = { ok: true; data: T } | { ok: false; field: string; message: string };
export function parse<T>(s: Shape<T>, v: unknown): Parsed<T> {
  try { return { ok: true, data: s(v, '') }; } catch (e) {
    if (e instanceof ShapeError) return { ok: false, field: e.field, message: e.message };
    throw e;
  }
}
