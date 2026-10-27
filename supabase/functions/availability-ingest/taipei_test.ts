import {
  parseTaipeiAvailability,
  parseTaipeiCapacities,
  parseTaipeiTime,
  rawInt,
} from './taipei.ts';

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}
function same(actual: unknown, expected: unknown, message: string) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  assert(a === e, `${message}: ${a} != ${e}`);
}

const fixture = (name: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/${name}`, import.meta.url));

Deno.test('the header time is Taiwan time (CST = UTC+8)', () => {
  same(
    parseTaipeiTime('Mon Oct 26 16:20:00 CST 2026')?.toISOString(),
    '2026-10-26T08:20:00.000Z',
    'UTC',
  );
  same(
    parseTaipeiTime('Thu Jan 01 03:00:00 CST 2026')?.toISOString(),
    '2025-12-31T19:00:00.000Z',
    'across midnight and the year',
  );
});

Deno.test('a time that does not read as one is null', () => {
  for (
    const text of [
      '',
      null,
      '2026-10-26 16:20:00',
      'Mon Oct 26 16:20:00 UTC 2026',
      'Mon Foo 26 16:20:00 CST 2026',
      'Mon Feb 31 16:20:00 CST 2026',
      'Mon Oct 26 25:20:00 CST 2026',
    ]
  ) {
    assert(parseTaipeiTime(text) === null, `${text} parsed`);
  }
});

Deno.test('raw values keep their codes; junk is null', () => {
  same([rawInt('12'), rawInt(' 0 '), rawInt('-9'), rawInt('-4')], [
    12,
    0,
    -9,
    -4,
  ], 'kept');
  same([rawInt(''), rawInt('abc'), rawInt('1.5'), rawInt(null)], [
    null,
    null,
    null,
    null,
  ], 'null');
});

Deno.test('the sample feed reads into lots', () => {
  const feed = parseTaipeiAvailability(
    fixture('taipei_allavailable_sample.xml'),
  );
  same(feed.updatedAt?.toISOString(), '2026-10-26T08:20:00.000Z', 'header');
  same(feed.parks.length, 5, 'every PARK');
  same(feed.parks[0], {
    id: 'TPE0001',
    scooter: -9,
    heavy: -9,
    car: 11,
  }, '-9 passes through for the database to read as no data');
  const byId = Object.fromEntries(feed.parks.map((p) => [p.id, p]));
  same(
    byId.TPE0318,
    { id: 'TPE0318', scooter: 36, heavy: 0, car: 0 },
    'counts',
  );
  same(byId.TPE0125.scooter, 0, 'zero is a count');
  same(
    byId.TPE0003.car,
    127,
    'the charging-station list inside a PARK is skipped',
  );
});

Deno.test('a missing tag is null, a BOM is ignored, a non-feed throws', () => {
  const feed = parseTaipeiAvailability(
    '﻿<DATA><UPDATETIME>Mon Oct 26 16:20:00 CST 2026</UPDATETIME>' +
      '<PARK><ID>TPE9</ID><AVAILABLEMOTOR>x</AVAILABLEMOTOR></PARK>' +
      '<PARK><AVAILABLEMOTOR>3</AVAILABLEMOTOR></PARK></DATA>',
  );
  same(
    feed.parks,
    [{ id: 'TPE9', scooter: null, heavy: null, car: null }],
    'parks',
  );
  same(
    parseTaipeiAvailability('<DATA><PARK><ID>A</ID></PARK></DATA>').updatedAt,
    null,
    'no header time',
  );
  let threw = false;
  try {
    parseTaipeiAvailability('<html>maintenance</html>');
  } catch {
    threw = true;
  }
  assert(threw, 'an HTML page is not a feed');
});

Deno.test('capacities read numbers and numeric strings', () => {
  const rows = parseTaipeiCapacities(fixture('taipei_alldesc_sample.json'));
  const byId = Object.fromEntries(rows.map((p) => [p.id, p]));
  same(
    byId.TPE0318,
    { id: 'TPE0318', scooter: 118, heavy: 1, car: 276 },
    'lot',
  );
  same(byId.TPE0001.scooter, 0, 'no scooter bays');
  same(
    parseTaipeiCapacities(
      '{"data":{"park":[{"id":"A","totalmotor":-1,"totallargemotor":"x","totalcar":2.5}]}}',
    ),
    [{ id: 'A', scooter: null, heavy: null, car: null }],
    'anything else is unknown',
  );
});
