import type { FaqItem } from '@/lib/types';
import { Html } from './Html';

export function Faq({ items }: { items: FaqItem[] }) {
  return (
    <div className="faq">
      {items.map((q) => (
        <details key={q.question}>
          <summary>{q.question}</summary>
          <div className="faq__a"><Html as="p" html={q.answer} /></div>
        </details>
      ))}
    </div>
  );
}
