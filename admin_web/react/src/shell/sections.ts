import type { LineIconName } from '../ui/icons';

export interface Section {
  path: string;
  label: string;
  icon: LineIconName;
  /** Phones show four tabs; the rest move under 「更多」. */
  phoneTab: boolean;
  /** Where the Flutter admin has this section, when not at `path`. */
  flutterPath?: string;
}

/** Navigation order from the canvas rail (TimedCase.dc.html). */
export const SECTIONS: readonly Section[] = [
  { path: '/review', label: '審核', icon: 'review', phoneTab: true },
  { path: '/pending', label: '待處理', icon: 'pending', phoneTab: true },
  { path: '/spots', label: '點位', icon: 'spots', phoneTab: true },
  { path: '/rules', label: '規則', icon: 'rules', phoneTab: false },
  { path: '/import', label: '匯入', icon: 'import', phoneTab: false, flutterPath: '/imports' },
  { path: '/users', label: '使用者', icon: 'users', phoneTab: false },
];

export const MORE: Section = { path: '/more', label: '更多', icon: 'more', phoneTab: true };

/** 更多 on the deployed site, where /more would land in the Flutter admin. */
export const LIVE_MORE_PATH = '/pending/more';

/** The sections still served by the Flutter admin are full page loads. */
export const sectionHref = (section: Section) => section.flutterPath ?? section.path;

/** Pages reached only from 「更多」 on a phone. */
export const MORE_PATHS = [
  '/more',
  LIVE_MORE_PATH,
  '/design',
  ...SECTIONS.filter((s) => !s.phoneTab).map((s) => s.path),
];

export function sectionLabel(pathname: string): string {
  if (pathname.startsWith('/design')) return '設計基礎';
  if (pathname === LIVE_MORE_PATH) return MORE.label;
  const section = [...SECTIONS, MORE].find((s) => pathname === s.path || pathname.startsWith(`${s.path}/`));
  return section?.label ?? '管理';
}
