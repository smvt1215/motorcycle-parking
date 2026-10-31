import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.108.1';

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The stored fee, condition, zones and segments of the spot a fee,
 * condition, zone or segment suggestion names, so its rules run on what it
 * leaves (design §4.3, §5.4; #188); undefined
 * for anything else or a spot not found, where the suggestion stands alone.
 */
export async function currentSpot(
  admin: SupabaseClient,
  body: Record<string, unknown>,
): Promise<Record<string, unknown> | undefined> {
  const proposed = body.proposed as Record<string, unknown> | undefined;
  if (
    body.action !== 'flag' || !proposed ||
    !['fee', 'condition', 'parking_zones', 'parking_segments'].some((k) =>
      k in proposed
    )
  ) return;
  const source = String(body.source_id);
  const official = source.startsWith('official:');
  const id = official ? source.slice('official:'.length) : source;
  if (!uuidPattern.test(id)) return;
  const { data } = await admin
    .from(official ? 'official_heavy_spots' : 'community_spots')
    .select('fee,condition,parking_zones,parking_segments')
    .eq('id', id)
    .maybeSingle();
  return data ?? undefined;
}
