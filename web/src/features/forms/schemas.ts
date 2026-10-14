import { z } from '@/lib/zod';

// One schema per form, used in the browser (field errors as you go) and again in the server action
// (docs/blueprint/08-forms.md section 2). Messages say how to fix the problem.
export const email = z.string().trim().min(1, 'Enter your email so we can reply.').max(200).regex(/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/, 'Enter an email address like name@example.com.');
export const phone = z.string().trim().refine((v) => v.replace(/\D/g, '').length >= 10, 'Enter a phone number with area code.').refine((v) => v.length <= 30, 'That number is too long.');
const optPhone = z.string().trim().max(30).refine((v) => !v || v.replace(/\D/g, '').length >= 10, 'Enter a phone number with area code.');
export const password = z.string().min(8, 'Use at least 8 characters.').max(200, 'Use at most 200 characters.');

export const contactSchema = z.object({
  topic: z.enum(['car', 'booking', 'dates', 'owner', 'billing', 'other']),
  name: z.string().trim().min(2, 'Enter your name.').max(100),
  email,
  phone: optPhone.optional().default(''),
  ref: z.string().trim().max(40).optional().default(''),
  message: z.string().trim().min(10, 'Write a short message so we know how to help.').max(2000, 'Keep it under 2,000 characters.')
});

export const ownerSchema = z.object({
  name: z.string().trim().min(2, 'Enter your name.').max(100),
  phone,
  email,
  carAddress: z.string().trim().min(5, 'Start typing the address where the car is kept.').max(300),
  year: z.coerce.number({ message: 'Enter the model year, for example 2021.' }).int().min(1990, 'Enter the model year, for example 2021.').max(new Date().getFullYear() + 1, 'Enter the model year, for example 2021.'),
  make: z.string().trim().min(2, 'Enter the make, for example Mercedes-Benz.').max(60),
  model: z.string().trim().min(1, 'Enter the model, for example C300.').max(60),
  own: z.enum(['Owned outright', 'Financed', 'Leased'], { message: 'Choose one.' }),
  who: z.enum(['Me, personally', 'My corporation'], { message: 'Choose one.' }),
  mode: z.enum(['managed', 'self', 'turo'])
});

export const signInSchema = z.object({ email, password: z.string().min(1, 'Enter your password.') });
export const signUpSchema = z.object({
  name: z.string().trim().min(2, 'Enter your name.').max(120),
  email, password,
  agree: z.literal(true, { message: 'Tick this box to create an account.' })
});
export const resetSchema = z.object({ email });
export const newPasswordSchema = z.object({ password, token: z.string().max(200).optional() });

export type FieldErrors = Record<string, string>;
export function fieldErrors(e: z.ZodError): FieldErrors {
  const out: FieldErrors = {};
  for (const i of e.issues) { const k = i.path.join('.'); if (!(k in out)) out[k] = i.message; }
  return out;
}
export type ActionResult<T = unknown> = { ok: true; data: T } | { ok: false; code: string; message: string; fieldErrors?: FieldErrors };
