import { Act } from '@/features/admin/Act';
import { $, Card, Kv, d } from '@/features/admin/ui';

// The car's value and fuel (1400, 1402), on the Admin and the staff car page: the Canadian Black Book value (or an
// estimate) that credit card coverage is checked against, the types the card exclusions see, and the tank, battery and
// grade the fuel shortfall at each return is priced from. Admin and Fleet edit it; customer service reads it.
export interface ValueFuelData {
  vehicle_id: string; black_book_value_cents: number | null; black_book_checked_on: string | null; estimated_value_cents: number | null;
  value: { cents: number | null; source: 'black_book' | 'estimate' | null; on: string | null }; coverage_types: string[];
  fuel: string | null; fuel_tank_litres: number | null; battery_kwh: number | null; fuel_grade: string | null; grade_used: string;
  tank_default_litres: number; battery_default_kwh: number;
}

export function ValueFuel({ v, canEdit, refresh }: { v: ValueFuelData | null; canEdit: boolean; refresh: string[] }) {
  if (!v) return null;
  const ev = v.fuel === 'electric';
  return (
    <Card title="Value and fuel" testId="vehicle-value-fuel">
      <Kv rows={[
        ['Value for card coverage', v.value.cents ? `${$(v.value.cents)} (${v.value.source === 'black_book' ? `Canadian Black Book${v.value.on ? `, ${d(v.value.on)}` : ''}` : 'estimate'})` : 'None on file: renters on card coverage go to staff review'],
        ['Counted as', v.coverage_types.length ? v.coverage_types.join(', ') : 'No excluded type'],
        ev ? ['Battery', v.battery_kwh ? `${v.battery_kwh} kWh` : `${v.battery_default_kwh} kWh (the default)`]
          : ['Tank', v.fuel_tank_litres ? `${v.fuel_tank_litres} L` : `${v.tank_default_litres} L (the default)`],
        ...(ev ? [] : [['Fuel grade', `${v.grade_used}${v.fuel_grade ? '' : ' (from the class)'}`] as [string, string]])]} />
      {canEdit && (
        <Act ops inline action="vehicle_value_set" payload={{ vehicle_id: v.vehicle_id }} label="Save" refresh={refresh} testId="vehicle-value-fuel-save" fields={[
          { name: 'black_book_value_cents', label: 'Canadian Black Book value', type: 'money', value: v.black_book_value_cents },
          { name: 'black_book_checked_on', label: 'Black Book checked on', type: 'date', value: v.black_book_checked_on },
          { name: 'estimated_value_cents', label: 'Estimated value (when no Black Book)', type: 'money', value: v.estimated_value_cents },
          ...(ev ? [{ name: 'battery_kwh', label: 'Battery (kWh)', type: 'number' as const, value: v.battery_kwh }]
            : [{ name: 'fuel_tank_litres', label: 'Tank (litres)', type: 'number' as const, value: v.fuel_tank_litres },
               { name: 'fuel_grade', label: 'Fuel grade', type: 'select' as const, value: v.fuel_grade ?? '', options: [['', 'From the class'], ['regular', 'Regular'], ['premium', 'Premium'], ['diesel', 'Diesel']] as Array<[string, string]> }])]} />)}
    </Card>
  );
}
