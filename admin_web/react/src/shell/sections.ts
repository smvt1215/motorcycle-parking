import type { LineIconName } from '../ui/icons';

export interface Section {
  path: string;
  label: string;
  icon: LineIconName;
  /** Phones show four tabs; the rest move under 「更多」. */
  phoneTab: boolean;
}

/** Navigation order from the canvas rail (Main.dc.html). */
export const SECTIONS: readonly Section[] = [
  { path: '/review', label: '審核', icon: 'review', phoneTab: true },
  { path: '/spots', label: '點位', icon: 'spots', phoneTab: true },
  { path: '/rules', label: '規則', icon: 'rules', phoneTab: true },
  { path: '/import', label: '匯入', icon: 'import', phoneTab: false },
  { path: '/users', label: '使用者', icon: 'users', phoneTab: false },
];

export const MORE: Section = { path: '/more', label: '更多', icon: 'more', phoneTab: true };

/** Pages reached only from 「更多」 on a phone. */
export const MORE_PATHS = ['/more', '/design', ...SECTIONS.filter((s) => !s.phoneTab).map((s) => s.path)];

export function sectionLabel(pathname: string): string {
  if (pathname.startsWith('/design')) return '設計基礎';
  const section = [...SECTIONS, MORE].find((s) => pathname === s.path || pathname.startsWith(`${s.path}/`));
  return section?.label ?? '管理';
}
