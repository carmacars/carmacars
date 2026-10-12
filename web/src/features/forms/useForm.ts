'use client';
import { startTransition, useActionState, useState, type FormEvent } from 'react';
import type { z } from 'zod';
import { fieldErrors, type ActionResult, type FieldErrors } from './schemas';

// Client side of the form contract: the same zod schema checks the fields before the server action
// runs (and the action checks again). The first field with a problem gets focus.
export function useForm<T extends z.ZodTypeAny>(schema: T, action: (prev: unknown, fd: FormData) => Promise<ActionResult<unknown>>, extra?: (fd: FormData) => Record<string, unknown>) {
  const [local, setLocal] = useState<FieldErrors>({});
  const [state, run, pending] = useActionState(async (prev: unknown, fd: FormData) => {
    const values = { ...Object.fromEntries(fd), ...(extra ? extra(fd) : {}) };
    const p = schema.safeParse(values);
    if (!p.success) {
      const fe = fieldErrors(p.error); setLocal(fe);
      requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fe } as ActionResult<unknown>;
    }
    setLocal({});
    return action(prev, fd);
  }, null as ActionResult<unknown> | null);
  const errors: FieldErrors = { ...(state && !state.ok ? state.fieldErrors ?? {} : {}), ...local };
  const clear = (k: string) => { if (local[k]) setLocal((l) => { const n = { ...l }; delete n[k]; return n; }); };
  // Submitted from onSubmit (not the form's action attribute), so React does not reset the fields
  // when the server sends back an error.
  const submit = (e: FormEvent<HTMLFormElement>) => { e.preventDefault(); const fd = new FormData(e.currentTarget); startTransition(() => run(fd)); };
  return { state, run: submit, pending, errors, clear };
}
