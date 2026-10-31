import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

// DESIGN.md is the source of truth; tokens.css must carry every value in it.
const read = (relative: string) => readFileSync(fileURLToPath(new URL(relative, import.meta.url)), 'utf8');

const designMd = read('../../../DESIGN.md');
const frontmatter = designMd.match(/^---\n([\s\S]*?)\n---\n/);
if (!frontmatter?.[1]) throw new Error('DESIGN.md has no frontmatter');
const design = parse(frontmatter[1]) as {
  colors: Record<string, string>;
  rounded: Record<string, string>;
  spacing: Record<string, string>;
};

const css = read('./tokens.css');
const declared = new Map(
  [...css.matchAll(/(--[a-z0-9-]+):\s*([^;]+);/g)].map((m) => [m[1]!, m[2]!.trim().toLowerCase()]),
);

describe('tokens.css matches DESIGN.md', () => {
  it.each(Object.entries(design.colors))('color %s', (name, value) => {
    expect(declared.get(`--color-${name}`)).toBe(value.toLowerCase());
  });

  it.each(Object.entries(design.rounded))('radius %s', (name, value) => {
    expect(declared.get(`--radius-${name}`)).toBe(value);
  });

  it.each(Object.entries(design.spacing))('spacing %s', (name, value) => {
    expect(declared.get(`--space-${name}`)).toBe(value);
  });

  it('declares no colour DESIGN.md does not name', () => {
    const extra = [...declared.keys()]
      .filter((key) => key.startsWith('--color-'))
      .map((key) => key.slice('--color-'.length))
      // Rail hover is drawn in Main.dc.html but has no frontmatter entry.
      .filter((name) => !(name in design.colors) && name !== 'rail-hover');
    expect(extra).toEqual([]);
  });
});
