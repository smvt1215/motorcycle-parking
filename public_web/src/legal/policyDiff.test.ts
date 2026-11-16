import { beforeEffective, policyDiff, taipeiDay } from './policyDiff';
import privacyPrevious from './privacy-1.5.md?raw';
import privacyText from './privacy.md?raw';

const strip = (markdown: string) =>
  markdown
    .split('\n')
    .filter((line) => !line.includes(''))
    .map((line) => line.replace(/\d+/, ''));

describe('taipeiDay and beforeEffective', () => {
  it('counts the day in Taiwan, not in UTC or the browser zone', () => {
    expect(taipeiDay(new Date('2026-11-21T15:59:59Z'))).toBe('2026-11-21');
    expect(taipeiDay(new Date('2026-11-21T16:00:00Z'))).toBe('2026-11-22');
  });

  it('is before the effective day until Taiwan midnight', () => {
    expect(beforeEffective('2026-11-22', new Date('2026-11-15T04:00:00Z'))).toBe(true);
    expect(beforeEffective('2026-11-22', new Date('2026-11-21T15:59:59Z'))).toBe(true);
    expect(beforeEffective('2026-11-22', new Date('2026-11-21T16:00:00Z'))).toBe(false);
    expect(beforeEffective('2026-11-22', new Date('2026-12-01T00:00:00Z'))).toBe(false);
  });
});

describe('policyDiff', () => {
  it('marks added and deleted lines, deletions first, as numbered runs', () => {
    const { markdown, changes } = policyDiff('a\n\n- one\n- two\n\nz', 'a\n\n- one\n- 2\n- three\n\nz');
    expect(changes).toBe(1);
    expect(markdown.split('\n')).toEqual([
      'a',
      '',
      '- one',
      '- 1two',
      '- 1' + '2',
      '- 1three',
      '',
      'z',
    ]);
  });

  it('keeps a replaced paragraph and its replacement as separate blocks', () => {
    const { markdown } = policyDiff('a\n\nold\n\nz', 'a\n\nnew\n\nz');
    expect(markdown).toContain('1old\n\n1new');
  });

  it('ignores the padding prettier adds to align a table', () => {
    const { changes } = policyDiff(
      '| a   | b |\n| --- | - |\n| x   | y |',
      '| a     | b |\n| ----- | --- |\n| x     | y |',
    );
    expect(changes).toBe(0);
  });

  it('keeps the new text exactly when the deletions are dropped (#475)', () => {
    const { markdown, changes } = policyDiff(privacyPrevious, privacyText);
    expect(changes).toBeGreaterThan(0);
    const squash = (lines: string[]) =>
      lines
        .map((line) => line.replace(/\s+$/, '').replace(/(\S) {2,}/g, '$1 '))
        .map((line) => (/^\|[\s:|-]+\|$/.test(line) ? '|sep|' : line))
        .filter((line) => line !== '');
    expect(squash(strip(markdown))).toEqual(squash(privacyText.split('\n')));
  });
});
