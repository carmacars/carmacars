'use client';
import { useRouter } from 'next/navigation';
import type { ComponentProps, FormEvent } from 'react';
import { scrollOption } from '@/lib/nav/same-page';

// A filter form (method="get") that applies its filters without reloading the page or throwing it back to the top
// (Release 27). With no script it still works as a plain GET form. Empty fields are left out of the address, as the
// browser leaves them in when it submits, so the addresses stay short.
export function GetForm({ action, children, onSubmit, ...rest }: Omit<ComponentProps<'form'>, 'method' | 'action'> & { action: string }) {
  const router = useRouter();
  const go = (e: FormEvent<HTMLFormElement>) => {
    onSubmit?.(e as never);
    if (e.defaultPrevented) return;
    e.preventDefault();
    const q = new URLSearchParams();
    for (const [k, v] of new FormData(e.currentTarget).entries()) if (typeof v === 'string' && v !== '') q.append(k, v);
    const to = `${action}${q.size ? `?${q}` : ''}`;
    router.push(to, scrollOption(to));
  };
  return <form method="get" action={action} onSubmit={go} {...rest}>{children}</form>;
}
