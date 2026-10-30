import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_eod_va_sales',
  audience: 'staff_va_sales',
  slot: 'eod',
  role: 'Sales',
  queue: 'va_sales',
  contains: 'applications received today and whether each was answered, documents signed today, upfront invoices paid today, applications with no contact for 3 days',
  summary: '2 applications came in and both were answered. 1 owner signed today.',
  stats: [{ label: 'Applications today', value: '2' }, { label: 'Signed today', value: '1' }],
  sections: [
    { title: 'Signed today', items: [
      { line: 'Lena Park: 2022 Mazda CX-5 GS', meta: 'Upfront invoice sent, $1,130.00.', url: 'https://carmacars.ca/staff/leads?application=app-0311' },
    ] },
    { title: 'No contact for 3 days', items: [
      { line: 'Northline Autos Inc.: 2 vehicles', meta: 'Documents sent, not opened.', url: 'https://carmacars.ca/staff/leads?application=app-0314' },
    ] },
  ],
});
