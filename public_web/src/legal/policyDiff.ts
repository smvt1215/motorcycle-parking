// The announced next version shown over the current one, like a Git diff
// (user, 2026-11-15, #475): during the notice period /privacy keeps the
// current text and marks, line by line, what the next version adds and
// deletes. Both texts are the published Markdown files, so the marks are
// computed here and can never disagree with either version.
import type { Element, ElementContent, Root, RootContent } from 'hast';

export type DiffKind = 'ins' | 'del';

/** Private-use characters around a change number at the start of a line. */
const INS = '';
const DEL = '';
const END = '';

/** The day in Taiwan (YYYY-MM-DD) at [now]. */
export function taipeiDay(now: Date): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Taipei',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
}

/** Whether a version taking effect on [effective] is still only announced. */
export function beforeEffective(effective: string, now: Date): boolean {
  return taipeiDay(now) < effective;
}

/** Prettier pads table cells to align them; the padding is not content. */
function normalize(line: string): string {
  const trimmed = line.replace(/\s+$/, '');
  if (/^\|[\s:|-]+\|$/.test(trimmed)) {
    const cells = trimmed.split('|').length - 2;
    return `|${' --- |'.repeat(cells)}`;
  }
  return trimmed.replace(/(\S) {2,}/g, '$1 ');
}

const separator = /^\|( --- \|)+$/;

type Op = { kind: 'same' | DiffKind; line: string };

/** Longest-common-subsequence line diff, old to new. */
function diffLines(before: string[], after: string[]): Op[] {
  const n = before.length;
  const m = after.length;
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i]![j] =
        before[i] === after[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const ops: Op[] = [];
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && before[i] === after[j]) {
      ops.push({ kind: 'same', line: before[i]! });
      i++;
      j++;
    } else if (j < m && (i === n || lcs[i]![j + 1]! >= lcs[i + 1]![j]!)) {
      ops.push({ kind: 'ins', line: after[j]! });
      j++;
    } else {
      ops.push({ kind: 'del', line: before[i]! });
      i++;
    }
  }
  // Git's order: within a run of changes, what goes before what comes.
  const ordered: Op[] = [];
  for (let k = 0; k < ops.length;) {
    if (ops[k]!.kind === 'same') {
      ordered.push(ops[k++]!);
      continue;
    }
    const run: Op[] = [];
    while (k < ops.length && ops[k]!.kind !== 'same') run.push(ops[k++]!);
    ordered.push(...run.filter((op) => op.kind === 'del'), ...run.filter((op) => op.kind === 'ins'));
  }
  return ordered;
}

/** A list item, numbered item, heading or table row keeps its marker first. */
const prefix = /^(\s*(?:#{1,6} |[-*] |\d+\. |\| )?)/;

export interface PolicyDiff {
  /** The merged Markdown, changed lines carrying a mark for [markChanges]. */
  markdown: string;
  /** How many runs of changed lines there are, numbered from 1. */
  changes: number;
}

/** Merges [before] and [after] into one Markdown text with marked lines. */
export function policyDiff(before: string, after: string): PolicyDiff {
  const ops = diffLines(before.split('\n').map(normalize), after.split('\n').map(normalize));
  const out: string[] = [];
  let changes = 0;
  let inRun = false;
  for (const { kind, line } of ops) {
    if (kind === 'same') {
      inRun = false;
      out.push(line);
      continue;
    }
    // A deleted blank line or table separator has nothing to show; an added
    // one only keeps the blocks apart.
    if (line.trim() === '' || separator.test(line)) {
      if (kind === 'ins') out.push(line);
      continue;
    }
    if (!inRun) changes++;
    inRun = true;
    const [lead] = line.match(prefix)!;
    const mark = `${kind === 'ins' ? INS : DEL}${changes}${END}`;
    const marked = `${lead}${mark}${line.slice(lead.length)}`;
    // A plain paragraph next to its replacement must stay its own block.
    if (lead === '') {
      if (out.length && out[out.length - 1]!.trim() !== '') out.push('');
      out.push(marked, '');
    } else {
      out.push(marked);
    }
  }
  return { markdown: out.join('\n'), changes };
}

/** The anchor of a run of changes. */
export function changeId(change: number): string {
  return `change-${change}`;
}

const blocks = new Set(['p', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'td', 'th']);

function text(value: string): ElementContent {
  return { type: 'text', value };
}

/** The label (outside, so it is never struck through), then the text. */
function wrap(kind: DiffKind, children: ElementContent[], tag?: string): ElementContent[] {
  const marked: Element = { type: 'element', tagName: kind, properties: {}, children };
  if (!tag) return [marked];
  return [
    {
      type: 'element',
      tagName: 'span',
      properties: { className: ['policy-diff-tag'] },
      children: [text(tag)],
    },
    marked,
  ];
}

/**
 * A rehype plugin: each marked line's block becomes `<ins>` or `<del>` with
 * a label in words (not only color), and the first block of each run gets
 * its [changeId].
 */
export function markChanges(labels: Record<DiffKind, string>) {
  return () => (tree: Root) => {
    // Found first, changed after, so no change disturbs the walk.
    const marks: { node: { value: string }; path: Element[] }[] = [];
    const visit = (node: Root | Element, path: Element[]) => {
      for (const child of node.children as RootContent[]) {
        if (child.type === 'element') visit(child, [...path, child]);
        else if (child.type === 'text' && /^\s*[\uE000\uE001]/.test(child.value)) {
          marks.push({ node: child, path });
        }
      }
    };
    visit(tree, []);
    const seen = new Set<number>();
    for (const { node, path } of marks) {
      const found = /^(\s*)([\uE000\uE001])(\d+)\uE002/.exec(node.value);
      if (!found) continue;
      node.value = found[1]! + node.value.slice(found[0].length);
      const kind: DiffKind = found[2] === INS ? 'ins' : 'del';
      const change = Number(found[3]);
      const block = [...path].reverse().find((el) => blocks.has(el.tagName));
      if (!block) continue;
      const cell = block.tagName === 'td' || block.tagName === 'th';
      const row = cell ? path[path.indexOf(block) - 1] : undefined;
      const target = row ?? block;
      target.properties = {
        ...target.properties,
        className: ['policy-diff', `policy-diff--${kind}`],
      };
      if (!seen.has(change)) {
        seen.add(change);
        target.properties.id = changeId(change);
      }
      if (row) {
        // The row's whitespace text nodes are not cells.
        const cells = row.children.filter((c): c is Element => c.type === 'element');
        cells.forEach((c, index) => {
          c.children = wrap(kind, c.children, index === 0 ? labels[kind] : undefined);
        });
      } else {
        // A list item's nested list is not part of its own line.
        const nested = block.children.findIndex(
          (c) => c.type === 'element' && (c.tagName === 'ul' || c.tagName === 'ol'),
        );
        const own = nested < 0 ? block.children : block.children.slice(0, nested);
        const rest = nested < 0 ? [] : block.children.slice(nested);
        block.children = [...wrap(kind, own, labels[kind]), ...rest];
      }
    }
  };
}
