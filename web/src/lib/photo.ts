import { publicEnv } from './public-env';
// Address of a file in the public photo bucket (NEXT_PUBLIC_VEHICLE_PHOTOS_URL).
export const photoUrl = (path: string) => (/^https?:\/\//.test(path) ? path : `${publicEnv.photosUrl}/${path.replace(/^\//, '')}`);
