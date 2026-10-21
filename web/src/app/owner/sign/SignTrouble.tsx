import Link from 'next/link';

// What the sign page shows when something on the server failed (logged): never a crashed page.
export function SignTrouble({ retry }: { retry?: React.ReactNode }) {
  return (
    <section className="stack" data-testid="sign-trouble" aria-labelledby="sg-trouble">
      <h1 className="d2" id="sg-trouble">Your documents did not load</h1>
      <p>Something went wrong on our side while getting your documents ready. Nothing was signed and your details are safe.</p>
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
        {retry ?? <Link prefetch={false} className="btn btn--primary" href="/owner/sign">Try again</Link>}
        <Link prefetch={false} className="btn btn--ghost" href="/owner">Back to the owner portal</Link>
      </div>
      <p className="small muted">If it keeps happening, call or email us and we will sort it out.</p>
    </section>
  );
}
