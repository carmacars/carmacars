import { publicEnv } from './public-env';
// Address of a file in the public photo bucket (NEXT_PUBLIC_VEHICLE_PHOTOS_URL).
// A built-in sample photo (migration 0054) is a static asset of the site itself: /sample-photos/<body type>.jpg; so is an
// add-on's studio illustration (0079): /addon-photos/<code>.svg.
export const photoUrl = (path: string) => (/^https?:\/\//.test(path) || path.startsWith('/sample-photos/') || path.startsWith('/addon-photos/') ? path : `${publicEnv.photosUrl}/${path.replace(/^\//, '')}`);
