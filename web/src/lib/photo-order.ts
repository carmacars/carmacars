// r43 (2690): which photo of a car is its first. One rule, the same as the database's app.photo_rank (migration 2690):
// the exterior front three-quarter shot (front_left, the standard angle on the showroom background) first; a car without it
// gets its best other exterior; an interior or detail photo is never first while an exterior photo exists. A made cover
// (cover_model, cover_flyer: shot "cover_...") is the exterior cover with a model or a flyer on it and stays first.
// The database orders every list the site, the cards, the feeds and the channels read (app.public_listing_photos,
// app.cover_photo); this file is for code that holds a list of photos and must still pick a first one (the OG image, the
// Marketplace kit, the review's cover, tests).

/** Rank of each exterior shot, the best first. */
const EXTERIOR: Record<string, number> = {
  front_left: 0, front_right: 1, front: 2, rear_left: 3, rear_right: 4, left: 5, right: 6, rear: 7, exterior_more: 8
};
/** Rank of anything that is not an exterior shot (dashboard, seats, trunk, wheel, other detail): always after every exterior. */
export const NOT_EXTERIOR_RANK = 20;
/** A made cover is the first photo whatever the rest says. */
export const MADE_COVER_RANK = -1;

export const isExteriorShot = (shot: string | null | undefined) => !!shot && Object.hasOwn(EXTERIOR, shot);

/** The rank of a shot type (lower is earlier). */
export function photoRank(shot: string | null | undefined): number {
  if (!shot) return NOT_EXTERIOR_RANK;
  if (shot.startsWith('cover_')) return MADE_COVER_RANK;
  return Object.hasOwn(EXTERIOR, shot) ? EXTERIOR[shot]! : NOT_EXTERIOR_RANK;
}

export interface OrderablePhoto { shot?: string | null; shot_type?: string | null; is_cover?: boolean | null; sort_order?: number | null }
const shotOf = (p: OrderablePhoto) => p.shot ?? p.shot_type ?? null;

/** The photos in the order a car shows them: by rank, then the one marked cover, then the order given (a stable sort). */
export function orderPhotos<T extends OrderablePhoto>(photos: readonly T[]): T[] {
  return photos.map((p, i) => ({ p, i }))
    .sort((a, b) => photoRank(shotOf(a.p)) - photoRank(shotOf(b.p)) || Number(!!b.p.is_cover) - Number(!!a.p.is_cover)
      || (a.p.sort_order ?? 0) - (b.p.sort_order ?? 0) || a.i - b.i)
    .map((x) => x.p);
}

/** The first photo of a car, or null. */
export const primaryPhoto = <T extends OrderablePhoto>(photos: readonly T[] | null | undefined): T | null => (photos?.length ? orderPhotos(photos)[0]! : null);

/** True when the car has photos and the first of them is not an exterior (the car has no exterior photo at all). */
export function primaryNotExterior(photos: readonly OrderablePhoto[] | null | undefined): boolean {
  const p = primaryPhoto(photos);
  return !!p && photoRank(shotOf(p)) >= NOT_EXTERIOR_RANK;
}
