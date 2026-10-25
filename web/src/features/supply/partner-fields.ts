import type { Field } from '@/features/admin/Act';

// The partner record's fields (Admin > Partners), the same for adding and changing a partner.
export function PARTNER_FIELDS(p: Record<string, unknown>): Field[] {
  return [
    { name: 'business_name', label: 'Business name', required: true, value: p.business_name },
    { name: 'legal_name', label: 'Legal name (if different)', value: p.legal_name },
    { name: 'contact_name', label: 'Contact person (signs the agreement)', value: p.contact_name },
    { name: 'contact_title', label: 'Their title', value: p.contact_title },
    { name: 'email', label: 'Email', type: 'email', value: p.email },
    { name: 'phone', label: 'Phone', type: 'tel', value: p.phone },
    { name: 'address_line1', label: 'Street address', type: 'address', value: p.address_line1 },
    { name: 'city', label: 'City', value: p.city },
    { name: 'postal_code', label: 'Postal code', value: p.postal_code },
    { name: 'hst_number', label: 'HST number', value: p.hst_number },
    { name: 'commission_bps', label: 'Commission (empty: the default in Program settings)', type: 'percent', value: p.commission_bps },
    { name: 'insurance_company', label: 'Their insurance company', value: p.insurance_company },
    { name: 'insurance_policy', label: 'Policy number', value: p.insurance_policy },
    { name: 'insurance_expiry', label: 'Insurance expiry', type: 'date', value: p.insurance_expiry },
    { name: 'contacts', label: 'Other contacts (JSON list: name, role, email, phone)', type: 'json', value: p.contacts ?? [] },
    { name: 'status', label: 'Status', type: 'select', required: true, value: p.status ?? 'active', options: [['active', 'Active'], ['paused', 'Paused'], ['ended', 'Ended']] },
    { name: 'notes', label: 'Notes', type: 'textarea', value: p.notes }
  ];
}
