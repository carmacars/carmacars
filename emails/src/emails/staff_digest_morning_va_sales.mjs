import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_morning_va_sales',
  audience: 'staff_va_sales',
  slot: 'morning',
  role: 'Sales',
  queue: 'va_sales',
  contains: 'owner applications not yet answered, owners with documents sent but not signed, upfront invoices unpaid, onboardings waiting on an owner document, registry visits in the next 7 days',
  summary: '1 application needs a reply today and 2 owners have not signed.',
  stats: [{ label: 'Applications to answer', value: '1' }, { label: 'Waiting on owners', value: '3' }],
  sections: [
    { title: 'Applications to answer', items: [
      { line: 'Daniel Rossi: 2023 Toyota RAV4 XLE', meta: 'Received yesterday 3:20 pm Reply due today.', url: 'https://carmacars.ca/staff/leads?application=app-0318' },
    ] },
    { title: 'Documents sent, not signed', items: [
      { line: 'Lena Park: 2022 Mazda CX-5 GS', meta: 'Sent 4 days ago. Sign-by date is Friday.', url: 'https://carmacars.ca/staff/leads?application=app-0311' },
      { line: 'Northline Autos Inc.: 2 vehicles', meta: 'Sent 2 days ago.', url: 'https://carmacars.ca/staff/leads?application=app-0314' },
    ] },
    { title: 'Waiting on an owner document', items: [
      { line: 'Omar Haddad: lender permission letter', meta: 'Asked 6 days ago. Safety certificate ends Nov 6.', url: 'https://carmacars.ca/staff/leads?application=app-0305' },
    ] },
  ],
});
