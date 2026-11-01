import { type Claimed, type Deps, handle, sameSecret } from './handler.ts';

const userA = '10000000-0000-4000-8000-000000000001';
const userB = '10000000-0000-4000-8000-000000000002';

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}
function equal(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}: ${a} !== ${e}`);
}

type Options = {
  cancelled?: string[];
  avatars?: Record<string, string[]>;
  fail?: 'claim' | 'prepare' | 'list' | 'remove' | 'delete' | 'finish';
  stuck?: boolean;
};

function fake(claimed: Claimed[], options: Options = {}) {
  const avatars: Record<string, string[]> = structuredClone(
    options.avatars ?? {},
  );
  const log: string[] = [];
  const deps: Deps = {
    secret: 's3cret',
    claim: (limit) =>
      options.fail === 'claim'
        ? Promise.reject(new Error('db'))
        : Promise.resolve(claimed.slice(0, limit)),
    prepare: (request) => {
      if (options.fail === 'prepare') return Promise.reject(new Error('db'));
      return Promise.resolve(
        options.cancelled?.includes(request) ? null : { spots: 2, votes: 1 },
      );
    },
    listAvatars: (user, limit) => {
      if (options.fail === 'list') return Promise.reject(new Error('s'));
      return Promise.resolve((avatars[user] ?? []).slice(0, limit));
    },
    removeAvatars: (paths) => {
      if (options.fail === 'remove') return Promise.reject(new Error('s'));
      log.push(`remove ${paths.join(',')}`);
      if (!options.stuck) {
        for (const path of paths) {
          const [user, name] = path.split('/');
          avatars[user] = (avatars[user] ?? []).filter((n) => n !== name);
        }
      }
      return Promise.resolve();
    },
    deleteUser: (user) => {
      if (options.fail === 'delete') return Promise.reject(new Error('a'));
      log.push(`delete ${user}`);
      return Promise.resolve();
    },
    finish: (request, source, counts) => {
      if (options.fail === 'finish') return Promise.reject(new Error('db'));
      log.push(`finish ${request} ${source} ${JSON.stringify(counts)}`);
      return Promise.resolve();
    },
    fail: (request, error) => {
      log.push(`fail ${request} ${error}`);
      return Promise.resolve();
    },
  };
  return { deps, log };
}

const post = (secret = 's3cret') =>
  new Request('http://local/account-deletion', {
    method: 'POST',
    headers: { 'x-deletion-secret': secret },
    body: '{}',
  });

const a: Claimed = { request_id: 'ra', user_id: userA, source: 'app' };
const b: Claimed = { request_id: 'rb', user_id: userB, source: 'web' };

Deno.test('only the shared secret may run it', async () => {
  const { deps, log } = fake([a]);
  equal((await handle(post('wrong'), deps)).status, 403, 'wrong secret');
  equal(
    (await handle(post(''), { ...deps, secret: '' })).status,
    403,
    'unset secret refuses everyone',
  );
  equal(
    (await handle(new Request('http://local/', { method: 'GET' }), deps))
      .status,
    405,
    'POST only',
  );
  equal(log, [], 'nothing deleted');
});

Deno.test('removes avatars, then the account, then audits', async () => {
  const { deps, log } = fake([a, b], {
    avatars: { [userA]: ['x.jpg', 'y.png'] },
  });
  const res = await handle(post(), deps);
  equal(res.status, 200, 'ok');
  equal(await res.json(), { executed: 2, skipped: 0, failed: 0 }, 'result');
  equal(log, [
    `remove ${userA}/x.jpg,${userA}/y.png`,
    `delete ${userA}`,
    'finish ra app {"spots":2,"votes":1,"avatars":2}',
    `delete ${userB}`,
    'finish rb web {"spots":2,"votes":1,"avatars":0}',
  ], 'order');
});

Deno.test('a cancelled request is skipped', async () => {
  const { deps, log } = fake([a], { cancelled: ['ra'] });
  equal(
    await (await handle(post(), deps)).json(),
    { executed: 0, skipped: 1, failed: 0 },
    'skipped',
  );
  equal(log, [], 'nothing touched');
});

Deno.test('a failed step keeps the account and is recorded', async () => {
  for (
    const [fail, code] of [
      ['prepare', 'prepare_failed'],
      ['list', 'storage_failed'],
      ['remove', 'storage_failed'],
      ['delete', 'auth_delete_failed'],
    ] as const
  ) {
    const { deps, log } = fake([a, b], {
      fail,
      avatars: { [userA]: ['x.jpg'], [userB]: ['z.jpg'] },
    });
    const res = await handle(post(), deps);
    equal(res.status, 500, `${fail}: reported`);
    assert(log.includes(`fail ra ${code}`), `${fail}: recorded as ${code}`);
    assert(!log.some((l) => l.startsWith('finish')), `${fail}: no audit`);
    assert(!log.includes(`delete ${userA}`) || fail !== 'delete', 'kept');
  }
});

Deno.test('avatars that do not go away fail the request', async () => {
  const { deps, log } = fake([a], {
    stuck: true,
    avatars: { [userA]: ['x.jpg'] },
  });
  equal((await handle(post(), deps)).status, 500, 'failed');
  assert(log.includes('fail ra storage_failed'), 'recorded');
  assert(!log.includes(`delete ${userA}`), 'account kept');
});

Deno.test('a failed audit after deletion still counts as executed', async () => {
  const { deps, log } = fake([a], { fail: 'finish' });
  equal(
    await (await handle(post(), deps)).json(),
    { executed: 1, skipped: 0, failed: 0 },
    'executed',
  );
  assert(!log.some((l) => l.startsWith('fail')), 'not released');
});

Deno.test('a failed claim deletes nothing', async () => {
  const { deps, log } = fake([a], { fail: 'claim' });
  equal((await handle(post(), deps)).status, 500, 'reported');
  equal(log, [], 'nothing');
});

Deno.test('sameSecret', () => {
  assert(sameSecret('abc', 'abc'), 'same');
  assert(!sameSecret('abc', 'abd'), 'different');
  assert(!sameSecret('abc', 'abcd'), 'longer');
});
