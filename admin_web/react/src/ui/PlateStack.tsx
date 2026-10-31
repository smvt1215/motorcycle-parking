import { pairLabel, STATUS_LABEL, VEHICLE_LABEL, type PlateStatus, type Vehicle } from './eligibility';
import './PlateStack.css';

interface PlateStackProps {
  vehicle: Vehicle;
  status: PlateStatus;
  size?: 'small' | 'large';
  /** Overrides the default 「普通機車可停」 label, e.g. 「建議改為可停」. */
  label?: string;
}

/**
 * The App's stacked plates (lib/features/map/vehicle_sheet.dart PlateStack):
 * a rear plate top-left and a front plate offset down-right. The status is
 * drawn by treatment, never by colour alone, and always named in the label.
 */
export function PlateStack({ vehicle, status, size = 'small', label }: PlateStackProps) {
  return (
    <span
      role="img"
      aria-label={label ?? `${VEHICLE_LABEL[vehicle]}${STATUS_LABEL[status]}`}
      className={`plate-stack plate-stack--${vehicle} plate-stack--${status} plate-stack--${size}`}
      data-status={status}
    >
      <i className="plate-stack__rear" />
      <i className="plate-stack__front" />
    </span>
  );
}

interface EligibilityPairProps {
  scooter: PlateStatus;
  heavy: PlateStatus;
}

/** Both vehicles as one image: 普通機車 left, 大型重機 right, one label. */
export function EligibilityPair({ scooter, heavy }: EligibilityPairProps) {
  return (
    <span role="img" aria-label={pairLabel(scooter, heavy)} className="eligibility-pair">
      <PlateStack vehicle="scooter" status={scooter} />
      <PlateStack vehicle="heavy" status={heavy} />
    </span>
  );
}
