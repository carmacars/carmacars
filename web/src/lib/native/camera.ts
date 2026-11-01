// The store app's camera for the site's photo fields (migration 0390): licence, selfie, condition and field photos. The
// site's file inputs already ask for the camera (capture="environment" or "user"); in the app a tap on such an input
// opens the native camera (Capacitor Camera) instead of the WebView's file chooser, and the photo comes back into the
// same input as a file, so every form keeps working unchanged. An image-only input without capture offers the camera or
// the photo library; anything else (PDFs, several files at once) keeps the phone's own chooser. An input marked
// data-native-camera="off" is never taken over. No imports: the shell and the unit tests share it.

export type PhotoMode = { source: 'CAMERA' | 'PROMPT'; direction: 'REAR' | 'FRONT' };

export interface InputFacts { type: string; accept: string; capture: string | null; multiple: boolean; disabled: boolean; optOut: boolean }

/** How the app takes this input's photo, or null to leave the input to the phone's own chooser. */
export function photoModeFor(i: InputFacts): PhotoMode | null {
  if (i.type !== 'file' || i.disabled || i.optOut) return null;
  const accepts = i.accept.split(',').map((a) => a.trim().toLowerCase()).filter(Boolean);
  const imageOnly = accepts.length > 0 && accepts.every((a) => a.startsWith('image/') || ['.jpg', '.jpeg', '.png', '.heic', '.heif', '.webp'].includes(a));
  const direction = (i.capture ?? '').toLowerCase() === 'user' ? 'FRONT' : 'REAR';
  // a camera field (the site's "Take photo" buttons; their "Choose a file" sibling takes PDFs and saved photos)
  if (i.capture !== null) return i.multiple ? null : { source: 'CAMERA', direction };
  return imageOnly && !i.multiple ? { source: 'PROMPT', direction } : null;
}

export function factsOf(el: HTMLInputElement): InputFacts {
  return { type: el.type, accept: el.accept ?? '', capture: el.getAttribute('capture'), multiple: el.multiple, disabled: el.disabled,
    optOut: el.dataset.nativeCamera === 'off' };
}

/** The Camera plugin's options for a photo: a JPEG up to 2400 px, upright, not saved to the phone's library. */
export function cameraOptions(m: PhotoMode): Record<string, unknown> {
  return { resultType: 'base64', quality: 85, width: 2400, correctOrientation: true, saveToGallery: false, allowEditing: false,
    source: m.source, direction: m.direction, promptLabelHeader: 'Add a photo', promptLabelPhoto: 'Choose from library',
    promptLabelPicture: 'Take a photo', promptLabelCancel: 'Cancel' };
}

/** The plugin's base64 photo as a File for the input. */
export function photoFile(base64: string, format = 'jpeg', now = Date.now()): File {
  const bin = atob(base64.replace(/^data:[^,]*,/, ''));
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const ext = /^(png|webp|heic|gif)$/i.test(format) ? format.toLowerCase() : 'jpeg';
  return new File([bytes], `photo-${now}.${ext === 'jpeg' ? 'jpg' : ext}`, { type: `image/${ext}`, lastModified: now });
}

/** The camera said the person closed it: not an error to show. */
export function cancelled(e: unknown): boolean {
  return /cancel|denied by user|no image picked/i.test(e instanceof Error ? e.message : String(e ?? ''));
}
