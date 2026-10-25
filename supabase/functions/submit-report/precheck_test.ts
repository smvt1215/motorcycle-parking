import cases from './precheck_cases.json' with { type: 'json' };
import rulesFile from './precheck_rules.json' with { type: 'json' };
import { isPlaceholder, precheck, precheckResponse } from './precheck.ts';
import { validate } from './validate.ts';

const sorted = (values: string[]) => [...values].sort();

Deno.test('shared precheck cases break exactly the expected rules', () => {
  for (const { name, body, expect } of cases.cases) {
    const got = precheck(body as Record<string, unknown>).map((i) =>
      `${i.rule}@${i.field}`
    );
    if (JSON.stringify(sorted(got)) !== JSON.stringify(sorted(expect))) {
      throw new Error(`${name}: got ${JSON.stringify(got)}`);
    }
  }
});

Deno.test('every rule has a hit and messages fill their parameters', () => {
  const hit = new Set(
    cases.cases.flatMap((c) => c.expect.map((e) => e.split('@')[0])),
  );
  for (const code of Object.keys(rulesFile.rules)) {
    if (!hit.has(code)) throw new Error(`no case hits ${code}`);
  }
  for (const { body } of cases.cases) {
    for (const issue of precheck(body as Record<string, unknown>)) {
      if (/[{}]/.test(issue.message)) {
        throw new Error(`unfilled message: ${issue.message}`);
      }
    }
  }
});

Deno.test('hard refusals are limited to personal data and links', () => {
  // §0 item 10: everything else is a fix the rider can resend.
  for (const [code, rule] of Object.entries(rulesFile.rules)) {
    const reject = code.startsWith('pii_') || code.startsWith('ad_');
    if ((rule.action === 'reject') !== reject) {
      throw new Error(`${code} is ${rule.action}`);
    }
  }
});

Deno.test('a blocked report says what to fix in a body old apps also read', () => {
  const fix = precheck({
    action: 'create',
    spot: { name: '測試', space_type: 'heavyOnly', scooter_allowed: true },
  });
  const body = precheckResponse(fix);
  if (
    body.action !== 'fix' || body.error !== 'precheck fix' ||
    body.issues.length !== 2 || !body.message.includes('請')
  ) throw new Error(JSON.stringify(body));
  const reject = precheckResponse(
    precheck({
      action: 'create',
      spot: { name: '測試', space_type: 'car', note: '0912345678' },
    }),
  );
  // A refusal leads with the refusal, so its reason is the one shown.
  if (reject.action !== 'reject' || !reject.message.includes('電話')) {
    throw new Error(JSON.stringify(reject));
  }
});

Deno.test('cases are requests the structural validation accepts', () => {
  // Otherwise a case would test a request the function never prechecks.
  const ids = {
    device_id: '10000000-0000-4000-8000-000000000001',
    spot_id: '10000000-0000-4000-8000-000000000002',
    source_id: '10000000-0000-4000-8000-000000000002',
  };
  for (const { name, body } of cases.cases) {
    const full: Record<string, unknown> = { ...ids, ...body };
    if (full.action === 'create') {
      full.spot = { lat: 25, lng: 121, city: '臺北市', ...body.spot };
    }
    // Official spots hide by a flag, community spots by status.
    if ((body as { proposed?: { hidden?: boolean } }).proposed?.hidden) {
      full.source_id = `official:${ids.source_id}`;
    }
    const error = validate(full);
    if (error) throw new Error(`${name}: ${error}`);
  }
});

Deno.test('placeholders are whole values, not words inside a name', () => {
  for (const text of ['測試', ' asdf ', 'Test.', '？？？', '無']) {
    if (!isPlaceholder(text)) throw new Error(`${text} passed`);
  }
  for (const text of ['', '  ', '測試站', '無障礙機車格', '123 號前']) {
    if (isPlaceholder(text)) throw new Error(`${text} blocked`);
  }
});
