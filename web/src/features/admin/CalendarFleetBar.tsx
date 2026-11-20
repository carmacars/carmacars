'use client';
import { AVAIL_FILTERS, GROUPS, filterCount, options, type AvailFilter, type FleetCar, type FleetFilter, type GroupBy } from './calendar-fleet';

// The fleet calendar's second toolbar row (r48 ops): find a car in a long list. Filters by car status, class, owner and
// availability; the cars in groups that fold; how many cars show and how many are free today. Owner is left out for a
// role that is not given owners (customer service and Sales).
export function CalendarFleetBar({ cars, filter, onFilter, groupBy, onGroupBy, shown, freeToday, groups, allFolded, onFoldAll, onClear, dirty }: {
  cars: FleetCar[]; filter: FleetFilter; onFilter: (f: FleetFilter) => void; groupBy: GroupBy; onGroupBy: (g: GroupBy) => void;
  shown: number; freeToday: number; groups: number; allFolded: boolean; onFoldAll: (fold: boolean) => void; onClear: () => void; dirty: boolean;
}) {
  const statuses = options(cars, 'status'), classes = options(cars, 'class'), owners = options(cars, 'owner');
  const set = (patch: Partial<FleetFilter>) => onFilter({ ...filter, ...patch });
  const n = filterCount(filter);
  return (
    <div className="mcal__fleet" data-testid="cal-fleet-bar">
      <div className="mcal__filters" role="group" aria-label="Filter the cars">
        <label className="vh" htmlFor="cal-f-status">Car status</label>
        <select className="select" id="cal-f-status" value={filter.status} onChange={(e) => set({ status: e.target.value })} data-testid="cal-f-status" data-on={filter.status ? 'yes' : undefined}>
          <option value="">Any car status</option>{statuses.map(([v, l, c]) => <option key={v} value={v}>{l} ({c})</option>)}</select>
        <label className="vh" htmlFor="cal-f-class">Class</label>
        <select className="select" id="cal-f-class" value={filter.cls} onChange={(e) => set({ cls: e.target.value })} data-testid="cal-f-class" data-on={filter.cls ? 'yes' : undefined}>
          <option value="">Any class</option>{classes.map(([v, l, c]) => <option key={v} value={v}>{l} ({c})</option>)}</select>
        {owners.length > 0 && <>
          <label className="vh" htmlFor="cal-f-owner">Owned by</label>
          <select className="select mcal__f-owner" id="cal-f-owner" value={filter.owner} onChange={(e) => set({ owner: e.target.value })} data-testid="cal-f-owner" data-on={filter.owner ? 'yes' : undefined}>
            <option value="">Any owner</option>{owners.map(([v, l, c]) => <option key={v} value={v}>{l} ({c})</option>)}</select></>}
        <label className="vh" htmlFor="cal-f-avail">Availability</label>
        <select className="select" id="cal-f-avail" value={filter.avail} onChange={(e) => set({ avail: e.target.value as AvailFilter })} data-testid="cal-f-avail" data-on={filter.avail ? 'yes' : undefined}>
          {AVAIL_FILTERS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        {dirty && <button className="btn btn--quiet btn--sm" type="button" onClick={onClear} data-testid="cal-clear">Clear{n ? ` ${n} filter${n === 1 ? '' : 's'}` : ' filters'}</button>}
      </div>
      <div className="mcal__grouping">
        <label className="small" htmlFor="cal-group">Group by</label>
        <select className="select" id="cal-group" value={groupBy} onChange={(e) => onGroupBy(e.target.value as GroupBy)} data-testid="cal-group">
          {GROUPS.filter(([v]) => v !== 'owner' || owners.length > 0).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        {groupBy !== 'none' && groups > 0 && <button className="btn btn--ghost btn--sm" type="button" onClick={() => onFoldAll(!allFolded)} data-testid="cal-fold-all" aria-pressed={allFolded}>{allFolded ? 'Open every group' : 'Fold every group'}</button>}
        <p className="mcal__count small" role="status" data-testid="cal-count"><b>{shown}</b> of {cars.length} cars{shown ? <> · <span>{freeToday} free today</span></> : null}</p>
      </div>
    </div>
  );
}
