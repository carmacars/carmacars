// Whether a fleet row has an address on the site (0310). The database gives every published car a slug; the site
// still leaves out a row without one, so no page ever links /cars/null. No imports: unit tested in Node.
export const hasAddress = (c: { slug?: unknown } | null | undefined): boolean => !!c && typeof c.slug === 'string' && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(c.slug);
