import Link from 'next/link';

export const metadata = { title: 'Page not found', robots: { index: false } };

export default function NotFound() {
  return (
    <section className="nf on-dark">
      <div className="wrap nf__in">
        <p className="nf__code" aria-hidden="true">404</p>
        <div className="stack">
          <h1 className="d1">Wrong turn.</h1>
          <p className="lead muted">Not every road comes back around. This page is not here: it may have moved, or the link was mistyped.</p>
          <p className="row"><Link className="btn btn--primary btn--lg" href="/cars">See the fleet</Link><Link className="btn btn--ghost btn--lg" href="/">Go home</Link></p>
          <ul className="nf__links"><li><Link className="link" href="/how-it-works">How it works</Link></li><li><Link className="link" href="/requirements">Requirements</Link></li><li><Link className="link" href="/faq">FAQ</Link></li><li><Link className="link" href="/contact">Contact</Link></li></ul>
        </div>
      </div>
    </section>
  );
}
