-- Update already-initialized databases as well as fresh installations.
-- Direct reads (including favorite validation) must hide future-dated bays.
drop policy official_read on public.official_heavy_spots;
create policy official_read on public.official_heavy_spots
  for select to anon,authenticated using(effective_date<=current_date);
