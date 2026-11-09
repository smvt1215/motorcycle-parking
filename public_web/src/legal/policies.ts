// The published policies: their text lives in Markdown next to this file so a
// revision (e.g. after the lawyer's review) only swaps the file and bumps the
// version and dates here.
import privacyText from './privacy.md?raw';
import termsText from './terms.md?raw';

export interface Policy {
  title: string;
  /** Shown on the page; bump on every published change. */
  version: string;
  /** ISO dates (Taiwan calendar day). */
  effective: string;
  updated: string;
  markdown: string;
  /** The notice above the text until the professional review is done (user, 2026-11-07). */
  notice: string;
}

/** User decisions 2026-11-07 (PM_ANS Q_PRIVACY_PAGE): version 1.0, dated the day it goes live. */
export const privacy: Policy = {
  title: '隱私權政策',
  version: '1.2',
  effective: '2026-11-09',
  updated: '2026-11-09',
  markdown: privacyText,
  notice:
    '這份政策尚待專業人士審閱，之後可能調整。調整時會更新版本與生效日期，並在「十二、政策修改」說明改了什麼。',
};

/** The privacy policy's layout and the same notice (PM 2026-11-07). */
export const terms: Policy = {
  title: '服務條款',
  version: '1.2',
  effective: '2026-11-09',
  updated: '2026-11-09',
  markdown: termsText,
  notice:
    '這份條款尚待專業人士審閱，之後可能調整。調整時會更新版本與生效日期，並依「第 11 條　條款修改」通知你。',
};

/** 「2026 年 11 月 7 日」 */
export function dateLabel(iso: string): string {
  const [year, month, day] = iso.split('-').map(Number);
  return `${year} 年 ${month} 月 ${day} 日`;
}

/** The `## ` sections, in order: the table of contents. */
export function sections(markdown: string): string[] {
  return [...markdown.matchAll(/^## (.+)$/gm)].map((match) => match[1]!.trim());
}

/** A stable anchor for a section, from its position. */
export function sectionId(index: number): string {
  return `section-${index + 1}`;
}
