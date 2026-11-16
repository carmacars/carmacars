// r48 part 2: the hint beside a greyed-out button, saying what to do first (the pattern of Propose a change's Send, 3050).
// The button names it with aria-describedby; it shows only while there is a reason (lib/a11y/disabled-hints.ts checks
// that every such button has one).
export function WhyDisabled({ id, why }: { id: string; why: string | false | null | undefined }) {
  return why ? <span className="hint why-disabled" id={id} data-testid={id}>{why}</span> : null;
}
