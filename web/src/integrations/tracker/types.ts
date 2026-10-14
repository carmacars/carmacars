// The tracker module (docs/architecture.md section 4, migration 0042): what the app may ask the GPS tracker's
// service. The vendor's documentation is not in hand yet, so no real adapter exists: "none" answers every call
// with "not connected" and does nothing. Rules that already hold in the database stay: an engine disable needs an
// Admin's approval and a reading from the last five minutes with speed 0 and ignition off (0020); an adapter only
// sends what that row allows.
export const TRACKER_SOON = 'live location, the remote immobilize request and the mileage from the tracker. The tracker company\'s connection details are needed first; until then the readings on this page are entered by staff.';

export interface TrackerDevice { vehicleId: string; deviceId: string | null }
export interface Position { latitude: number; longitude: number; at: string; speedKmh: number | null; ignitionOn: boolean | null }
export interface Mileage { odometerKm: number; at: string }
export interface ImmobilizeRequest { commandId: string; reason: string; requestedBy: string }

export type TrackerResult<T> =
  | { ok: true; data: T }
  | { ok: false; reason: 'not_connected' | 'no_device' | 'device_offline' | 'refused' | 'error'; message: string };

export interface TrackerAdapter {
  readonly name: 'none';
  readonly connected: boolean;
  /** Where the car is now. */
  locate(d: TrackerDevice): Promise<TrackerResult<Position>>;
  /** Ask the device to stop the engine from restarting; only for a tracker_commands row an Admin approved (0020). */
  requestImmobilize(d: TrackerDevice, r: ImmobilizeRequest): Promise<TrackerResult<{ providerRef: string }>>;
  /** The odometer as the tracker last reported it. */
  mileage(d: TrackerDevice): Promise<TrackerResult<Mileage>>;
}
