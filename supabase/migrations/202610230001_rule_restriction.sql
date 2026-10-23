-- The kind of limit behind a rule's conditional space types; the app picks the
-- marker icon from it. 'unverified' means the rule itself is not verified, so
-- the spaces it lists are shown as unverified rather than conditional.
alter table public.city_rules add column restriction text
  check (restriction in ('pilot_area','signage','unverified'));
update public.city_rules set restriction='pilot_area' where vehicle='heavy' and city in ('新北市','桃園市');
update public.city_rules set restriction='signage' where vehicle='heavy' and city='臺中市';
update public.city_rules set restriction='unverified' where vehicle='heavy' and city='高雄市';
