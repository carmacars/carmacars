import type { Field } from '@/features/admin/Act';
import type { SheetRate } from './rates';

// The fields of a rate on the insurers' sheet (migration 0163): saving them adds a row from the date given; the rate
// before it stays in the history.
export function rateFields(r: Partial<SheetRate> | null | undefined, today: string): Field[] {
  return [
    { name: 'daily_rate_cents', label: 'Daily rate', type: 'money', required: true, value: r?.daily_rate_cents ?? null },
    { name: 'weekly_cap_cents', label: 'Weekly cap (empty: none)', type: 'money', value: r?.weekly_cap_cents ?? null, hint: 'The most the insurer pays for 7 days.' },
    { name: 'monthly_cap_cents', label: 'Cap for 30 days (empty: none)', type: 'money', value: r?.monthly_cap_cents ?? null },
    { name: 'delivery_allowance_cents', label: 'Delivery and pickup allowance (empty: none)', type: 'money', value: r?.delivery_allowance_cents ?? null, hint: 'The most the insurer pays for delivery and pickup on one rental.' },
    { name: 'km_per_day', label: 'Kilometres a day (0: unlimited, empty: not set)', type: 'number', min: 0, max: 5000, value: r?.km_per_day ?? null },
    { name: 'taxes_note', label: 'Taxes note (printed on the invoice)', value: r?.taxes_note ?? null, wide: true },
    { name: 'effective_from', label: 'From', type: 'date', required: true, value: today },
    { name: 'note', label: 'Why it changed (kept in the history)', type: 'textarea' }
  ];
}

export const removeFields = (today: string): Field[] => [
  { name: 'effective_from', label: 'No rate from', type: 'date', required: true, value: today },
  { name: 'note', label: 'Why (kept in the history)', type: 'textarea' }
];
