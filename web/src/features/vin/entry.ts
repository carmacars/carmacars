// The state of VIN-first entry (migration 0079) and what it sends, without React, so the unit tests read it
// (src/features/vin/entry.test.ts). The component is VinEntry.tsx.
import type { RateHint, VinFacts } from '../../server/actions/vin.ts';
import { cleanVin, vinState, type DecodedCar } from './vin.ts';

export interface CarEdits { year?: string; make?: string; model?: string; trim?: string; fuel?: string }
export interface VinValue {
  mode: 'vin' | 'plate';
  vin: string;
  plate: string;
  facts: VinFacts | null;
  /** what a person changed after the decode, or typed when there is no decode */
  edits: CarEdits;
  colour: string;
  class: string;
  classSource: 'inferred' | 'person';
  classWhy: string | null;
  rate: RateHint | null;
}
export const emptyVin = (): VinValue => ({ mode: 'vin', vin: '', plate: '', facts: null, edits: {}, colour: '', class: 'standard', classSource: 'inferred', classWhy: null, rate: null });

/** The car as it will be saved: the decode, with what a person changed on top. */
export function effectiveCar(v: VinValue): Partial<DecodedCar> {
  const d = v.facts?.decode;
  const e = v.edits;
  return {
    ...(d ?? {}),
    year: e.year ? Number(e.year) : d?.year ?? null, make: e.make ?? d?.make ?? null, model: e.model ?? d?.model ?? null,
    trim: e.trim !== undefined ? e.trim || null : d?.trim ?? null, fuel: e.fuel ?? d?.fuel ?? null
  };
}
/** True when the decode answered (the summary line shows); false asks year, make and model. */
export const decoded = (v: VinValue) => v.mode === 'vin' && !!v.facts?.decode;
/** What the form still needs: year, make and model when there is no decode, the VIN or plate. Null when it can be saved. */
export function vinProblem(v: VinValue): string | null {
  if (v.mode === 'vin' && vinState(v.vin).kind !== 'ok' && vinState(v.vin).kind !== 'check_digit') return 'Enter the 17-character VIN, or add the car by its plate.';
  if (v.mode === 'plate' && !/^[A-Z0-9 ]{2,8}$/i.test(v.plate.trim())) return 'Enter the plate.';
  const c = effectiveCar(v);
  if (!c.year || !c.make || !c.model) return v.mode === 'vin' && !v.facts ? 'Wait for the VIN to be looked up.' : 'Choose the year, make and model.';
  return null;
}
/** The payload fields for the car: only what the decode does not give (the database fills the rest from it). */
export function vinPayload(v: VinValue): Record<string, unknown> {
  const out: Record<string, unknown> = { class: v.class, class_source: v.classSource, colour: v.colour || undefined };
  if (v.mode === 'vin') out.vin = cleanVin(v.vin); else out.plate = v.plate.toUpperCase().replace(/\s/g, '');
  const d = v.mode === 'vin' ? v.facts?.decode : null;
  const e = v.edits;
  const put = (k: keyof CarEdits, cur: unknown) => { const x = e[k]; if (x !== undefined && String(x) !== String(cur ?? '')) out[k] = k === 'year' ? Number(x) : x; };
  if (!d) { const c = effectiveCar(v); out.year = c.year ?? undefined; out.make = c.make ?? undefined; out.model = c.model ?? undefined; if (c.trim) out.trim = c.trim; if (e.fuel) out.fuel = e.fuel; }
  else { put('year', d.year); put('make', d.make); put('model', d.model); put('trim', d.trim); put('fuel', d.fuel); }
  return out;
}

