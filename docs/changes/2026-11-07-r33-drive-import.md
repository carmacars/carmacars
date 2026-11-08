# Release 33, part J: import listing photos from a Google Drive link (0760, 0761)

The owner gives the car photos in bulk as public Google Drive folders (a top folder, one folder per make, then per car).
Admin, Fleet and customer service staff now paste the folder link instead of downloading and adding the photos by hand.

## What it does

- **One car.** On a car's listing page, under the capture: **Import photos from a Google Drive link**
  (`web/src/features/drive-import/DriveImport.tsx`, in `ListingPage`, so Admin and staff both have it). The folder and the
  folders inside it are read; every photo goes to that car.
- **Many cars.** **Cars > Import photos from Drive** (`/admin/vehicles/import-photos`, a button on Vehicles) and **Listings >
  Import photos from Drive** for staff (`/staff/listings/import-photos`, customer service and Fleet; the same component, in
  `STAFF_SHARED`). The page walks the whole tree and proposes a car for each folder with photos
  (`features/drive-import/drive-match.ts`: plate 100, make 25 or 20 from the folder above, model 40, year 20, colour 12; a wrong year or
  colour counts against; 01 Motors partner cars win a tie; a car already given to another folder ranks lower; two alike cars
  are marked **Check this one**). The table is confirmed or changed (car list with the likely cars first, tick Import, leave a
  folder out) before anything is imported.
- **Reading a folder without a key** (`drive-folder.ts`): the folder page `drive.google.com/drive/folders/<id>` carries its
  entries in `window['_DRIVE_ivd']` (escaped JSON: id, parents, name, mime type); subfolders are walked (4 levels, 400 folders).
  The page holds the first 50 entries only, so a folder that shows 50 is read again through the embedded folder view
  (`/embeddedfolderview?id=`, which lists every entry); if that does not add any, the folder gets a note saying so and the key
  is suggested. With the **Photo import from Google Drive** box in Settings (`program_settings.google_drive_api_key`, Admin) the Drive v3 API is
  used instead (`files.list` with the key, pages of 1000; downloads with `alt=media`).
- **Downloading**: `https://drive.usercontent.google.com/download?id=<id>&export=download&confirm=t` (no key), else the API. An
  HTML answer (quota, sign-in) is a reason, not a photo; the bytes decide the type, not the name. Images only: JPG, PNG, HEIC,
  WebP; `.DS_Store`, `Thumbs.db`, `._*`, hidden files, videos and documents are skipped (counted as other files). HEIC and WebP
  are made JPEG by Cloudflare Images from a private working copy (`PhotoProcessor.toJpeg`), because the listing pipeline takes
  JPEG and PNG.
- **The listing pipeline, unchanged**: each photo is stored in `vehicle-originals` and recorded with `app.record_listing_upload`
  as the person who started the run (the intake is started if the car has none; customer service can fill a started listing
  but cannot start one), with width and height read from the file (EXIF turn applied) and its sha256. The shot is sorted as
  **Add photos** sorts it (the vision model within the day's AI share; `server/listing-sort.ts` is the route's former inline code,
  now shared), else it is an extra photo, in file-name order (numbers in order, IMG_2 before IMG_10). Then the existing
  `process_photo` jobs, studio framing and plate check run. By default the listing is submitted when the photos are in
  (`Submit the listing ... when its photos are in`, on); a car with fewer than the minimum photos is reported as not submitted.
- **Idempotent**: a Drive file already imported to the same car (its photo still on the car) is skipped before it is downloaded;
  the same picture (sha256) already on the car is skipped; a photo taken off the car can be imported again. Two runs at once
  are serialized per car and file (advisory lock).
- **Background job** (`drive_imports`, `drive_import_folders`, `drive_import_files`, `src/server/drive-import.ts`,
  `/api/jobs/drive-import`): steps of one request each (scan 4 folders, or match, or take 3 photos), claimed with a lock (a step
  lost for 3 minutes is claimed again), each ending by starting the next through the Worker's service binding. The five-minute
  cron reaches it through `server_jobs_due` (`listing` is true while a run has work; the listing route starts it). The page polls
  every 4 seconds and starts a step itself if none holds the run.
- **Limits and politeness**: 15 MB a photo, 600 photos, 400 folders, 4 levels, 4 GB per run (`app.drive_import_limits`, enforced
  by the database); one request at a time with a 400 ms pause; a Drive that says too many requests / download quota is left alone
  for 2 minutes and the photo is tried 3 times (2 and 10 minutes between), then failed with the reason.
- **Summary**: imported, skipped, failed, each with its reason and path; **Try the failed photos again**; earlier imports listed.

## Who

`app.drive_import_may`: Admin, Fleet, customer service. Others (finance, sales, renters, owners) are refused by the database
and do not see the buttons (the hub entry has `fns: cs fleet`).

## Checks

`supabase/tests/99_r33_drive_import.sql` (permissions, scan, import, idempotency, same picture, failure reason, retry, bulk match
and confirm, cancel, limits, the cron gate, the key); unit tests `drive-folder.test.ts` (synthetic folder pages, the API, file
kinds, bytes), `drive-match.test.ts`, `image-size.test.ts`, `summary.test.ts`; e2e `tests/e2e/drive-import.spec.ts` (the page and
its link check; it cannot reach Google). Not verified against live Drive: the folder-page and embedded-view shapes are the ones
in use today, kept in two small parsers (`parseFolderPage`, `parseEmbeddedView`) so a change on Google's side is one fix.

## Guides

Changed chapters (published by `supabase/seed/0761_gen_guides.mjs` into `0761_r33_drive_import_guides.sql`):
`admin/fleet-and-listings` (Import photos from a Google Drive link), `va/fleet` (the same for Fleet and customer service).
