import Link from 'next/link';
import type { ReactNode } from 'react';

export function AuthShell({ side, sideText, children }: { side: string; sideText: string; children: ReactNode }) {
  return (
    <section className="auth">
      <div className="auth__side on-dark"><div className="auth__side-in stack"><p className="d2">{side}</p><p className="muted">{sideText}</p></div></div>
      <div className="auth__main"><div className="auth__box stack-lg">{children}</div></div>
    </section>
  );
}

export function AuthTabs({ current }: { current: 'in' | 'new' }) {
  return (
    <nav className="tabs" aria-label="Sign in or create an account">
      <Link className="tab" href="/sign-in" aria-current={current === 'in' ? 'page' : undefined} aria-selected={undefined}>Sign in</Link>
      <Link className="tab" href="/create-account" aria-current={current === 'new' ? 'page' : undefined}>Create account</Link>
    </nav>
  );
}
