import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import * as content from './content';

// The App's own words for the same deletion. Tests run from public_web/
// (jsdom gives import.meta.url no file: scheme).
const dart = readFileSync(resolve(process.cwd(), '../lib/domain/account_deletion_display.dart'), 'utf8');

/** The string literals of a `const name = [ ... ];` list in the Dart file. */
function dartList(name: string): string[] {
  const match = dart.match(new RegExp(`const ${name} = \\[([\\s\\S]*?)\\];`));
  if (!match?.[1]) throw new Error(`${name} not found in account_deletion_display.dart`);
  return [...match[1].matchAll(/'([^']*)'/g)].map((m) => m[1]!);
}

function dartString(name: string): string {
  const match = dart.match(new RegExp(`const ${name} =\\s*'([^']*)';`));
  if (!match?.[1]) throw new Error(`${name} not found in account_deletion_display.dart`);
  return match[1];
}

describe('the web says what the App says about deletion', () => {
  it('deletes the same data (the phone-only log says when it goes)', () => {
    const app = dartList('deletionDeleted');
    expect(content.deleted).toHaveLength(app.length);
    app.forEach((item, i) => expect(content.deleted[i]!.startsWith(item)).toBe(true));
  });

  it('deletes every linked sign-in with the account (#382)', () => {
    expect(content.deleted[0]).toBe('帳號與所有已連結的登入方式（Google、Apple）');
  });

  it('keeps the same contributions, anonymised', () => {
    expect([...content.kept]).toEqual(dartList('deletionKept'));
    expect(content.keptNote).toBe(dartString('deletionKeptNote'));
    expect(content.keptHeading).toBe(dartString('deletionKeptHeading'));
  });

  it('says the same about a suspension surviving deletion', () => {
    expect(content.retention).toContain(dartString('deletionSuspensionNote'));
  });

  it('describes the abuse hash the same way', () => {
    expect(content.hashBody.startsWith(dartString('deletionHashTitle'))).toBe(true);
    expect(content.hashBody).toContain(dartString('deletionHashDetail'));
    expect(content.hashHeading).toBe(dartString('deletionHashHeading'));
  });
});
