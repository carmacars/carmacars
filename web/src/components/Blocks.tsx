import Link from 'next/link';
import type { Trail } from '@/features/seo/meta';
import { Crumbs } from './Crumbs';

export function PageHead({ trail, h1, lead }: { trail: Trail; h1: string; lead: string }) {
  return <section className="page-head on-dark"><div className="wrap"><Crumbs trail={trail} /><h1 className="d1">{h1}</h1><p className="lead muted">{lead}</p></div></section>;
}

export function CtaBand({ h, p, btn = ['Find a car', '/cars'] }: { h: string; p: string; btn?: [string, string] }) {
  return (
    <section className="section--tight on-red cta-band">
      <div className="wrap cta-band__in"><div><h2 className="d2">{h}</h2><p className="lead">{p}</p></div><Link prefetch={false} className="btn btn--light btn--lg" href={btn[1]}>{btn[0]}</Link></div>
    </section>
  );
}
