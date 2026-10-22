// What a refund gives back (migration 0079). Staff choose it when they enter a refund: only a refund of the rental
// charge lowers the commission base; delivery, kilometres, add-ons and other charges never do.
export const REFUND_OF: [string, string][] = [
  ['rental', 'The rental charge'],
  ['delivery', 'Delivery or pickup'],
  ['kilometres', 'Kilometres'],
  ['addons', 'Add-ons'],
  ['other_charges', 'Other charges (fuel, cleaning, fees)'],
];
