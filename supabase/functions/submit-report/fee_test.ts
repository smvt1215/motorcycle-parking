import cases from '../_shared/parking_contract_cases.json' with {
  type: 'json',
};
import limit from '../_shared/fee_note_limit.json' with { type: 'json' };
import {
  feeNoteMaxLength,
  feeNoteOf,
  projectZoneFee,
  validFee,
  validFeePlans,
} from '../_shared/fee.ts';
import { validate } from './validate.ts';

// The same cases lib/models/fee.dart and the generated SQL run.
Deno.test('shared cases: validFee accepts exactly the valid fees', () => {
  if (cases.fees.length === 0) throw new Error('no cases');
  for (const { name, fee, valid } of cases.fees) {
    if (validFee(fee) !== valid) throw new Error(`${name}: expected ${valid}`);
  }
});

Deno.test('shared cases: feeNoteOf writes the shared sentences', () => {
  if (cases.fee_notes.length === 0) throw new Error('no cases');
  for (const { name, fee, note } of cases.fee_notes) {
    if (!validFee(fee)) throw new Error(`${name}: not a valid fee`);
    const got = feeNoteOf(fee);
    if (got !== note) throw new Error(`${name}: got ${got}`);
  }
});

Deno.test('the longest sentence is the generated bound', () => {
  if (!validFee(limit.longest_fee)) throw new Error('longest fee invalid');
  const got = feeNoteOf(limit.longest_fee).length;
  if (got !== feeNoteMaxLength || feeNoteMaxLength <= 200) {
    throw new Error(`got ${got}, bound ${feeNoteMaxLength}`);
  }
});

const device = '3f1c2a4e-0000-4000-8000-000000000001';
const longFee = limit.longest_fee;
const longNote = feeNoteOf(longFee);

Deno.test('a fee note longer than 200 must be the fee text', () => {
  const create = (spot: Record<string, unknown>) =>
    validate({
      device_id: device,
      action: 'create',
      spot: {
        name: '測試',
        lat: 25.05,
        lng: 121.5,
        city: '臺北市',
        space_type: 'paidMotorcycle',
        ...spot,
      },
    });
  if (create({ fee: longFee, fee_note: longNote }) !== null) {
    throw new Error('the fee text was refused');
  }
  if (create({ fee_note: 'x'.repeat(200) }) !== null) {
    throw new Error('200 characters of free text were refused');
  }
  for (
    const spot of [
      { fee_note: 'x'.repeat(201) },
      { fee: longFee, fee_note: `${longNote}。` },
      { fee_note: longNote },
    ]
  ) {
    if (create(spot) !== 'invalid fee_note') {
      throw new Error(`accepted ${JSON.stringify(spot).slice(0, 80)}`);
    }
  }
  const update = validate({
    device_id: device,
    action: 'update',
    spot_id: '3f1c2a4e-0000-4000-8000-000000000002',
    spot: { name: '測試', fee_note: longNote },
  });
  if (update !== 'invalid fee_note') throw new Error('update took a long note');
});

Deno.test('a suggested fee note longer than 200 must be the fee text', () => {
  const flag = (proposed: Record<string, unknown>) =>
    validate({
      device_id: device,
      action: 'flag',
      source_id: '3f1c2a4e-0000-4000-8000-000000000002',
      reason: '費率',
      field: 'fee_note',
      proposed,
    });
  if (flag({ fee: longFee, fee_note: longNote }) !== null) {
    throw new Error('the fee text was refused');
  }
  if (flag({ fee_note: longNote }) !== 'invalid proposed') {
    throw new Error('a long note without its fee was accepted');
  }
});

Deno.test('shared cases: validFeePlans', () => {
  if (cases.fee_plans.length === 0) throw new Error('no cases');
  for (const { name, plans, fee_plan, fee, zones, valid } of cases.fee_plans) {
    if (validFeePlans(plans, fee_plan, fee, zones) !== valid) {
      throw new Error(`${name}: expected ${valid}`);
    }
  }
});

Deno.test('shared cases: a plan projected onto a zone', () => {
  if (cases.fee_projections.length === 0) throw new Error('no cases');
  for (const { name, fee, zone, projected } of cases.fee_projections) {
    const got = projectZoneFee(
      fee as Record<string, unknown>,
      zone as Record<string, unknown>,
    );
    if (JSON.stringify(sortKeys(got)) !== JSON.stringify(sortKeys(projected))) {
      throw new Error(`${name}: got ${JSON.stringify(got)}`);
    }
  }
});

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') {
    return Object.fromEntries(
      Object.entries(v).sort(([a], [b]) => a < b ? -1 : 1).map((
        [k, x],
      ) => [k, sortKeys(x)]),
    );
  }
  return v;
}
