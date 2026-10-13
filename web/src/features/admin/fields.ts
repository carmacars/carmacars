import type { Field } from './Act';

// Form fields from a database row: the type follows the column's name and value, so a new setting
// appears on the settings screen without a developer.
const nice = (k: string) => { const s = k.replace(/_(cents|bps)$/, '').replace(/_/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); };
export function fieldFor(k: string, v: unknown, options?: Array<[string, string]>): Field {
  if (options) return { name: k, label: nice(k), type: 'select', options, value: v, required: true };
  if (typeof v === 'boolean') return { name: k, label: nice(k), type: 'bool', value: v };
  if (k.endsWith('_cents') && (typeof v === 'number' || v === null)) return { name: k, label: nice(k), type: 'money', value: v };
  if (k.endsWith('_bps') && (typeof v === 'number' || v === null)) return { name: k, label: nice(k), type: 'percent', value: v };
  if (typeof v === 'number') return { name: k, label: nice(k), type: 'number', value: v };
  if (v !== null && typeof v === 'object') return { name: k, label: nice(k), type: 'json', value: v };
  if (typeof v === 'string' && v.length > 80) return { name: k, label: nice(k), type: 'textarea', value: v };
  return { name: k, label: nice(k), type: 'text', value: v };
}
export const fieldsFrom = (row: Record<string, unknown>, keys: string[], options: Record<string, Array<[string, string]>> = {}) => keys.filter((k) => k in row).map((k) => fieldFor(k, row[k], options[k]));
