import { MATERIAL_PATHS } from './icons';
import './MapMarker.css';

export const MARKER_STATES = ['allowed', 'conditional', 'unverified', 'denied'] as const;
export type MarkerState = (typeof MARKER_STATES)[number];

export const MARKER_LABEL: Record<MarkerState, string> = {
  allowed: '可停',
  conditional: '有條件',
  unverified: '待確認',
  denied: '不可停',
};

const GLYPH: Record<Exclude<MarkerState, 'allowed'>, keyof typeof MATERIAL_PATHS> = {
  conditional: 'rule',
  unverified: 'question_mark',
  denied: 'close',
};

interface MapMarkerProps {
  state: MarkerState;
  /** 普大共用格: adds the white 「共」 badge. */
  shared?: boolean;
  selected?: boolean;
  /** Spot name, so the label reads 「復興南路…，可停」. */
  name?: string;
}

/**
 * The App's A0 marker (lib/features/map/map_legend.dart): the shape is the
 * meaning — circle 可停, rounded square 有條件／待確認, near-square 不可停.
 */
export function MapMarker({ state, shared = false, selected = false, name }: MapMarkerProps) {
  const label = [name, MARKER_LABEL[state], shared ? '普大共用格' : null].filter(Boolean).join('，');
  return (
    <span
      role="img"
      aria-label={label}
      className={`map-marker map-marker--${state}${selected ? ' map-marker--selected' : ''}`}
      data-state={state}
    >
      {state === 'allowed' ? (
        <span className="map-marker__p" aria-hidden="true">
          P
        </span>
      ) : (
        <svg viewBox="0 0 24 24" className="map-marker__glyph" aria-hidden="true" focusable="false">
          <path d={MATERIAL_PATHS[GLYPH[state]]} />
        </svg>
      )}
      {shared && (
        <span className="map-marker__badge" aria-hidden="true">
          共
        </span>
      )}
    </span>
  );
}
