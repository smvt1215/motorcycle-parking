import cases from './precheck_cases.json' with { type: 'json' };
import rulesFile from './precheck_rules.json' with { type: 'json' };
import {
  blocking,
  isPlaceholder,
  precheck,
  precheckResponse,
  riskFlags,
} from './precheck.ts';
import { currentSpot } from './current_spot.ts';
import { validate } from './validate.ts';

const sorted = (values: string[]) => [...values].sort();

Deno.test('shared precheck cases break exactly the expected rules', () => {
  for (const c of cases.cases) {
    const { name, body, expect } = c;
    const current = 'current' in c
      ? c.current as Record<string, unknown>
      : undefined;
    const got = precheck(body as Record<string, unknown>, current).map((i) =>
      `${i.rule}@${i.field}`
    );
    if (JSON.stringify(sorted(got)) !== JSON.stringify(sorted(expect))) {
      throw new Error(`${name}: got ${JSON.stringify(got)}`);
    }
    if ('blocking' in c) {
      const issues = precheck(body as Record<string, unknown>, current);
      if ((blocking(issues).length > 0) !== c.blocking) {
        throw new Error(`${name}: blocking ${!c.blocking}`);
      }
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

Deno.test('a hold lets the request through, flagged once per rule', () => {
  const issues = precheck({
    action: 'create',
    spot: {
      name: '信義路機車格',
      space_type: 'freeMotorcycle',
      condition: {
        bay: 'motorcycle',
        use: 'share',
        share: 'scooter_heavy',
        charge: 'free',
      },
    },
  });
  if (issues.length !== 1 || issues[0].action !== 'hold') {
    throw new Error(JSON.stringify(issues));
  }
  if (blocking(issues).length) throw new Error('a hold refused the report');
  if (
    JSON.stringify(riskFlags([...issues, ...issues])) !==
      '["share_free_needs_basis"]'
  ) {
    throw new Error('risk flags');
  }
  // Beside a fix, the refusal names the fix, not the hold.
  const mixed = precheck({
    action: 'create',
    spot: {
      name: '測試',
      space_type: 'freeMotorcycle',
      condition: {
        bay: 'motorcycle',
        use: 'share',
        share: 'scooter_heavy',
        charge: 'free',
      },
    },
  });
  const body = precheckResponse(blocking(mixed));
  if (body.action !== 'fix' || body.issues.some((i) => i.action === 'hold')) {
    throw new Error(JSON.stringify(body));
  }
});

/** A stand-in for the service client: records the table and id asked for. */
function fakeAdmin(row: Record<string, unknown> | null) {
  const asked: string[] = [];
  const admin = {
    from(table: string) {
      asked.push(table);
      return {
        select(columns: string) {
          asked.push(columns);
          return {
            eq(_: string, id: string) {
              asked.push(id);
              return { maybeSingle: () => Promise.resolve({ data: row }) };
            },
          };
        },
      };
    },
  };
  // deno-lint-ignore no-explicit-any
  return { admin: admin as any, asked };
}

Deno.test('currentSpot reads the stored fee and condition of the spot a suggestion names', async () => {
  const id = '3f1c2a4e-0000-4000-8000-000000000002';
  const stored = { fee: { car: { mode: 'free' } }, condition: null };
  const flag = (source: string, proposed: Record<string, unknown>) => ({
    action: 'flag',
    source_id: source,
    proposed,
  });
  let fake = fakeAdmin(stored);
  let got = await currentSpot(fake.admin, flag(id, { fee: {} }));
  if (
    got !== stored ||
    fake.asked.join() !== `community_spots,fee,condition,${id}`
  ) {
    throw new Error(fake.asked.join());
  }
  fake = fakeAdmin(stored);
  got = await currentSpot(
    fake.admin,
    flag(`official:${id}`, { space_type: 'car', condition: null }),
  );
  if (got !== stored || fake.asked[0] !== 'official_heavy_spots') {
    throw new Error(fake.asked.join());
  }
  // A spot not found, a source that is no row, or a suggestion of another
  // field: the suggestion stands alone.
  fake = fakeAdmin(null);
  if (await currentSpot(fake.admin, flag(id, { fee: {} })) !== undefined) {
    throw new Error('missing spot');
  }
  for (
    const body of [
      flag('tdx:123', { fee: {} }),
      flag(id, { name: '新名稱' }),
      { action: 'create', spot: {} },
    ]
  ) {
    fake = fakeAdmin(stored);
    if (
      await currentSpot(fake.admin, body) !== undefined || fake.asked.length
    ) {
      throw new Error(JSON.stringify(body));
    }
  }
});
