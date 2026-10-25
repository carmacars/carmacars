import type { Field } from '@/features/admin/Act';
import { KIND_OPTIONS, PAYOUT_METHODS } from './model';

// The fields of Add a referral partner and Edit (migration 0164). The address fills city, province and postal code from a suggestion.
export interface PartnerValues { kind?: string; business_name?: string; contact_name?: string | null; phone?: string | null; email?: string | null; address_line1?: string | null; city?: string | null;
  province?: string | null; postal_code?: string | null; payout_method?: string; payout_email?: string | null; rate_kind?: string; flat_cents?: number; rate_bps?: number; referral_code?: string; notes?: string | null }
export const PARTNER_FIELDS = (v: PartnerValues, defaults: { flat_cents: number; percent_bps: number }, editing = false): Field[] => [
  { name: 'kind', label: 'Kind of business', type: 'select', required: true, options: KIND_OPTIONS as unknown as Array<[string, string]>, value: v.kind ?? 'body_shop' },
  { name: 'business_name', label: 'Business name', type: 'text', required: true, value: v.business_name },
  { name: 'contact_name', label: 'Contact', type: 'text', value: v.contact_name },
  { name: 'phone', label: 'Phone', type: 'tel', value: v.phone },
  { name: 'email', label: 'Email', type: 'email', value: v.email },
  { name: 'address_line1', label: 'Address (start typing: city and postal code fill in)', type: 'address', value: v.address_line1, wide: true },
  { name: 'city', label: 'City', type: 'text', value: v.city },
  { name: 'province', label: 'Province', type: 'text', value: v.province ?? 'ON' },
  { name: 'postal_code', label: 'Postal code', type: 'text', value: v.postal_code },
  { name: 'payout_method', label: 'How we pay them', type: 'select', required: true, options: PAYOUT_METHODS, value: v.payout_method ?? 'e_transfer' },
  { name: 'payout_email', label: 'e-Transfer email', type: 'email', value: v.payout_email },
  { name: 'rate_kind', label: 'Kickback', type: 'select', required: true, options: [['flat', 'A flat amount for each completed rental'], ['percent', 'A percentage of the rental charge (after discounts)']], value: v.rate_kind ?? 'flat',
    hint: editing ? 'A change applies to rentals tied to the partner from now on; what is already earned keeps its rate.' : undefined },
  { name: 'flat_cents', label: 'Flat amount', type: 'money', value: v.flat_cents ?? defaults.flat_cents, hint: 'Used when the kickback is a flat amount. $50 unless you change it.' },
  { name: 'rate_bps', label: 'Percentage', type: 'percent', value: v.rate_bps ?? defaults.percent_bps, hint: 'Used when the kickback is a percentage.' },
  ...(editing ? [{ name: 'referral_code', label: 'Code (4 to 12 letters and digits)', type: 'text' as const, value: v.referral_code, hint: 'Changing it ends the old link and flyer.' }] : []),
  { name: 'notes', label: 'Notes (only Admins see them)', type: 'textarea', value: v.notes }
];
