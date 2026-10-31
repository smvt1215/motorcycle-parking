/** Vehicles always appear in this order: 普通機車 left, 大型重機 right. */
export const VEHICLES = ['scooter', 'heavy'] as const;
export type Vehicle = (typeof VEHICLES)[number];

/**
 * How a plate stack is drawn (DESIGN.md Plate Stack). This is display state,
 * not the stored contract: `notStated` exists only on official spots and
 * `legacyUnknown` only on rows written before 「未確認」 was cancelled.
 */
export const PLATE_STATUSES = ['allowed', 'conditional', 'denied', 'notStated', 'legacyUnknown'] as const;
export type PlateStatus = (typeof PLATE_STATUSES)[number];

export const VEHICLE_LABEL: Record<Vehicle, string> = {
  scooter: '普通機車',
  heavy: '大型重機',
};

export const STATUS_LABEL: Record<PlateStatus, string> = {
  allowed: '可停',
  conditional: '有條件可停',
  denied: '不可停',
  notStated: '官方未標示',
  legacyUnknown: '待確認（舊資料）',
};

/** 「普通機車可停，大型重機不可停」 */
export function pairLabel(scooter: PlateStatus, heavy: PlateStatus): string {
  return `${VEHICLE_LABEL.scooter}${STATUS_LABEL[scooter]}，${VEHICLE_LABEL.heavy}${STATUS_LABEL[heavy]}`;
}
