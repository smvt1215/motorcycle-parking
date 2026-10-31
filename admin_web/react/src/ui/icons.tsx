import type { SVGProps } from 'react';

/** 22px, 1.8 stroke line icons drawn on the canvas (Main.dc.html rail). */
const LINE_ICONS = {
  review: (
    <>
      <path d="M9 4h6v3H9zM7 5H5v15h14V5h-2" />
      <path d="M8.5 13l2.5 2.5 4.5-5" />
    </>
  ),
  spots: (
    <>
      <path d="M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11z" />
      <circle cx="12" cy="10" r="2.2" />
    </>
  ),
  rules: (
    <>
      <path d="M5 4h10l4 4v12H5z" />
      <path d="M9 12h6M9 16h6M9 8h3" />
    </>
  ),
  import: (
    <>
      <path d="M12 4v11M7 10l5 5 5-5" />
      <path d="M5 20h14" />
    </>
  ),
  users: (
    <>
      <circle cx="9" cy="8" r="3.2" />
      <path d="M3.5 19c.6-3 2.8-4.6 5.5-4.6s4.9 1.6 5.5 4.6" />
      <path d="M16 5.5a3 3 0 0 1 0 5.6M17.5 14.6c1.6.6 2.6 2 3 4.4" />
    </>
  ),
  more: (
    <>
      <circle cx="5.5" cy="12" r="1.3" />
      <circle cx="12" cy="12" r="1.3" />
      <circle cx="18.5" cy="12" r="1.3" />
    </>
  ),
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  arrow: <path d="M4 12h15M14 6l6 6-6 6" />,
} as const;

export type LineIconName = keyof typeof LINE_ICONS;

interface LineIconProps extends SVGProps<SVGSVGElement> {
  name: LineIconName;
  size?: number;
}

export function LineIcon({ name, size = 22, strokeWidth = 1.8, ...rest }: LineIconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {LINE_ICONS[name]}
    </svg>
  );
}

/**
 * Filled Material Icons used by the A0 map marker (Apache License 2.0,
 * https://github.com/google/material-design-icons): rule, close, question_mark.
 */
export const MATERIAL_PATHS = {
  rule: 'M16.54 11 13 7.46l1.41-1.41 2.12 2.12 4.24-4.24 1.41 1.41L16.54 11zM11 7H2v2h9V7zm10 6.41L19.59 12 17 14.59 14.41 12 13 13.41 15.59 16 13 18.59 14.41 20 17 17.41 19.59 20 21 18.59 18.41 16 21 13.41zM11 15H2v2h9v-2z',
  close:
    'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
  question_mark:
    'M11.07 12.85c.77-1.39 2.25-2.21 3.11-3.44.91-1.29.4-3.7-2.18-3.7-1.69 0-2.52 1.28-2.87 2.34L6.54 6.96C7.25 4.83 9.18 3 11.99 3c2.35 0 3.96 1.07 4.78 2.41.7 1.15 1.11 3.3.03 4.9-1.2 1.77-2.35 2.31-2.97 3.45-.25.46-.35.76-.35 2.24h-2.89c-.01-.78-.13-2.05.48-3.15zM14 20c0 1.1-.9 2-2 2s-2-.9-2-2 .9-2 2-2 2 .9 2 2z',
} as const;
