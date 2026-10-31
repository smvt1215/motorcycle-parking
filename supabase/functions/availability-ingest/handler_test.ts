import {
  type Deps,
  handle,
  type Outcome,
  publishedAt,
  sameSecret,
  type Source,
} from './handler.ts';
import type { ParkCapacity, ParkCounts } from './taipei.ts';

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

const now = new Date('2026-10-26T08:22:00Z');
const feedUrl = 'https://feed.test/TCMSV_allavailable.xml';
const descUrl = 'https://feed.test/TCMSV_alldesc.json';
const xml = Deno.readTextFileSync(
  new URL('./fixtures/taipei_allavailable_sample.xml', import.meta.url),
);
const desc = Deno.readTextFileSync(
  new URL('./fixtures/taipei_alldesc_sample.json', import.meta.url),
);

type Reply = Response | Error;

function fake(
  options: {
    source?: Partial<Source> | null;
    replies?: Record<string, Reply[]>;
    ingest?: Outcome;
  } = {},
) {
  const calls = {
    fetched: [] as { url: string; headers: Record<string, string> }[],
    capacities: [] as ParkCapacity[][],
    ingested: [] as {
      updatedAt: Date;
      parks: ParkCounts[];
      etag: string | null;
      publishedAt: Date | null;
    }[],
    records: [] as { outcome: Outcome; message: string }[],
    slept: 0,
  };
  const replies = options.replies ?? {
    [descUrl]: [new Response(desc)],
    [feedUrl]: [new Response(xml, { headers: { etag: '"v2"' } })],
  };
  const source: Source | null = options.source === null ? null : {
    key: 'taipei_tcmsv',
    enabled: true,
    feed_url: feedUrl,
    capacity_url: descUrl,
    etag: null,
    next_attempt_at: null,
    capacity_updated_at: null,
    ...options.source,
  };
  const deps: Deps = {
    secret: 's3cret',
    now: () => now,
    fetch(url, init) {
      calls.fetched.push({
        url,
        headers: (init.headers ?? {}) as Record<string, string>,
      });
      const next = replies[url]?.shift();
      if (!next) return Promise.reject(new TypeError('offline'));
      return next instanceof Error
        ? Promise.reject(next)
        : Promise.resolve(next);
    },
    sleep: () => {
      calls.slept++;
      return Promise.resolve();
    },
    source: () => Promise.resolve(source),
    storeCapacities(_key, rows) {
      calls.capacities.push(rows);
      return Promise.resolve();
    },
    ingest(_key, updatedAt, parks, etag, publishedAt) {
      calls.ingested.push({ updatedAt, parks, etag, publishedAt });
      return Promise.resolve({
        outcome: options.ingest ?? 'ok',
        rows: parks.length * 3,
      });
    },
    record(_key, outcome, message) {
      calls.records.push({ outcome, message });
      return Promise.resolve();
    },
  };
  return { deps, calls };
}

const post = (secret = 's3cret') =>
  new Request('https://fn.test/availability-ingest', {
    method: 'POST',
    headers: { 'x-ingest-secret': secret },
  });

Deno.test('only the scheduler, with the secret, may run it', async () => {
  const { deps, calls } = fake();
  assert((await handle(post('wrong'), deps)).status === 403, 'wrong secret');
  assert((await handle(post(''), deps)).status === 403, 'no secret');
  assert(
    (await handle(new Request('https://fn.test', { method: 'GET' }), deps))
      .status === 405,
    'GET',
  );
  assert(
    (await handle(post(), { ...deps, secret: '' })).status === 503,
    'an unset secret refuses everyone',
  );
  assert(calls.fetched.length === 0, 'nothing fetched');
  assert(
    sameSecret('abc', 'abc') && !sameSecret('abc', 'abd') &&
      !sameSecret('abc', 'ab'),
    'compare',
  );
});

Deno.test('a run reads capacities, then the feed, and stores it', async () => {
  const { deps, calls } = fake();
  const res = await handle(post(), deps);
  const body = await res.json();
  assert(res.status === 200, `status ${res.status}`);
  assert(body.outcome === 'ok', JSON.stringify(body));
  assert(
    body.source_updated_at === '2026-10-26T08:20:00.000Z',
    'source time, UTC+8',
  );
  assert(calls.capacities[0].length === 5, 'capacities stored');
  assert(calls.ingested[0].parks.length === 5, 'lots passed on');
  assert(calls.ingested[0].etag === '"v2"', 'etag kept');
  assert(calls.ingested[0].publishedAt === null, 'no Last-Modified, none sent');
  assert(
    calls.ingested[0].updatedAt.toISOString() === '2026-10-26T08:20:00.000Z',
    'the header time, not the fetch time',
  );
});

Deno.test('Last-Modified is passed on as the publish time', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
    replies: {
      [feedUrl]: [
        new Response(xml, {
          headers: { 'last-modified': 'Mon, 26 Oct 2026 08:21:12 GMT' },
        }),
      ],
    },
  });
  await handle(post(), deps);
  assert(
    calls.ingested[0].publishedAt?.toISOString() ===
      '2026-10-26T08:21:12.000Z',
    'publish time',
  );
});

Deno.test('an unreadable Last-Modified is no publish time', () => {
  assert(
    publishedAt(new Response('', { headers: { 'last-modified': 'soon' } })) ===
      null,
    'unreadable',
  );
});

Deno.test('recent capacities are not fetched again; the etag is sent', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z', etag: '"v1"' },
  });
  await handle(post(), deps);
  assert(
    calls.fetched.length === 1 && calls.fetched[0].url === feedUrl,
    'feed only',
  );
  assert(calls.fetched[0].headers['If-None-Match'] === '"v1"', 'conditional');
});

Deno.test('304 records unchanged and stores nothing', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z', etag: '"v1"' },
    replies: { [feedUrl]: [new Response(null, { status: 304 })] },
  });
  const body = await (await handle(post(), deps)).json();
  assert(body.outcome === 'unchanged', JSON.stringify(body));
  assert(calls.ingested.length === 0, 'nothing stored');
  assert(calls.records[0].outcome === 'unchanged', 'logged');
});

Deno.test('backoff skips the run without fetching', async () => {
  const { deps, calls } = fake({
    source: { next_attempt_at: '2026-10-26T08:40:00Z' },
  });
  const body = await (await handle(post(), deps)).json();
  assert(
    body.outcome === 'skipped' && body.reason === 'backoff',
    JSON.stringify(body),
  );
  assert(calls.fetched.length === 0, 'no fetch');
  assert(calls.records[0].outcome === 'skipped', 'logged');
});

Deno.test('a disabled source does nothing', async () => {
  const { deps, calls } = fake({ source: { enabled: false } });
  assert(
    (await (await handle(post(), deps)).json()).outcome === 'skipped',
    'skipped',
  );
  assert(calls.fetched.length === 0 && calls.records.length === 0, 'quiet');
});

Deno.test('a 5xx is retried once, then logged as an error', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
    replies: {
      [feedUrl]: [
        new Response('busy', { status: 503 }),
        new Response('busy', { status: 503 }),
      ],
    },
  });
  const res = await handle(post(), deps);
  assert(res.status === 502, `status ${res.status}`);
  assert(calls.fetched.length === 2 && calls.slept === 1, 'one retry');
  assert(calls.records[0].outcome === 'error', 'logged for backoff');
  assert(
    calls.records[0].message.includes('HTTP 503'),
    calls.records[0].message,
  );
});

Deno.test('a retry that succeeds stores the feed', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
    replies: {
      [feedUrl]: [new TypeError('reset') as Error, new Response(xml)],
    },
  });
  assert((await (await handle(post(), deps)).json()).outcome === 'ok', 'ok');
  assert(calls.ingested.length === 1, 'stored');
});

Deno.test('a future header time is refused before the database', async () => {
  const future = xml.replace(
    'Mon Oct 26 16:20:00 CST 2026',
    'Mon Oct 26 16:40:00 CST 2026',
  );
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
    replies: { [feedUrl]: [new Response(future)] },
  });
  assert((await handle(post(), deps)).status === 502, 'refused');
  assert(calls.ingested.length === 0, 'not stored');
  assert(calls.records[0].message.includes('future'), calls.records[0].message);
});

Deno.test('a page without a header time or lots is an error', async () => {
  for (
    const body of [
      '<DATA><PARK><ID>A</ID></PARK></DATA>',
      '<DATA><UPDATETIME>Mon Oct 26 16:20:00 CST 2026</UPDATETIME></DATA>',
      '<html>maintenance</html>',
    ]
  ) {
    const { deps, calls } = fake({
      source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
      replies: { [feedUrl]: [new Response(body)] },
    });
    assert((await handle(post(), deps)).status === 502, body);
    assert(calls.ingested.length === 0, `${body} stored`);
  }
});

Deno.test('without any capacities a failed description stops the run', async () => {
  const { deps, calls } = fake({
    replies: {
      [descUrl]: [new Response('x', { status: 404 })],
      [feedUrl]: [new Response(xml)],
    },
  });
  assert((await handle(post(), deps)).status === 502, 'stopped');
  assert(calls.ingested.length === 0, 'nothing stored');
});

Deno.test('with old capacities a failed description keeps them', async () => {
  const { deps, calls } = fake({
    source: { capacity_updated_at: '2026-10-25T00:00:00Z' },
    replies: {
      [descUrl]: [new Response('x', { status: 404 })],
      [feedUrl]: [new Response(xml)],
    },
  });
  const body = await (await handle(post(), deps)).json();
  assert(body.outcome === 'ok', JSON.stringify(body));
  assert(String(body.notes).includes('capacities kept'), JSON.stringify(body));
  assert(calls.ingested.length === 1, 'stored');
});

Deno.test('the database decides out-of-order feeds', async () => {
  const { deps } = fake({
    source: { capacity_updated_at: '2026-10-26T07:00:00Z' },
    ingest: 'out_of_order',
  });
  assert(
    (await (await handle(post(), deps)).json()).outcome === 'out_of_order',
    'passed through',
  );
});
