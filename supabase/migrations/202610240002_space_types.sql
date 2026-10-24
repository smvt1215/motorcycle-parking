-- Space kinds a rider meets beyond the original five, from Taipei's official
-- street-space codes (pktype 04/18, 20, 22) and electric-motorcycle bays.
-- Scooter areas (pktype 11) are motorcycle bays, paid or free like them.
-- Builds that predate them skip such rows instead of failing the map.
alter table public.community_spots drop constraint community_spots_space_type_check;
alter table public.community_spots add constraint community_spots_space_type_check
  check (space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet',
    'disabledMotorcycle','timedMotorcycle','flexShared','evMotorcycle'));
alter table public.official_heavy_spots drop constraint official_heavy_spots_space_type_check;
alter table public.official_heavy_spots add constraint official_heavy_spots_space_type_check
  check (space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet',
    'disabledMotorcycle','timedMotorcycle','flexShared','evMotorcycle'));
