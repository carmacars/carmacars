// The pages Ctrl+K finds (AdminCommand.tsx): every word typed must be in the page's name or its place in the menu;
// a name that starts with what was typed comes first, then a name with a word that starts with it, then the rest.
export interface Item { href: string; label: string; where: string; key?: string }

const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');

export function rank(items: Item[], q: string): Item[] {
  const n = norm(q.trim());
  if (!n) return items;
  const words = n.split(/\s+/);
  return items
    .map((i) => {
      const hay = norm(`${i.label} ${i.where}`);
      if (!words.every((w) => hay.includes(w))) return null;
      const l = norm(i.label);
      return { i, s: l.startsWith(n) ? 0 : l.split(/\s+/).some((w) => w.startsWith(words[0]!)) ? 1 : 2 };
    })
    .filter((x): x is { i: Item; s: number } => !!x)
    .sort((a, b) => a.s - b.s)
    .map((x) => x.i);
}
