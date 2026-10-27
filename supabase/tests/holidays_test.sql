begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- 114–116 年 are imported whole.
select is((select count(*)::integer from holidays where date between '2025-01-01' and '2027-12-31'),365*3,'114–116 年 every day');
select is((select array_agg(year order by year) from holiday_sources),array[2025,2026,2027],'a source per year');
select ok((select bool_and(source_url like 'https://www.dgpa.gov.tw/%') from holiday_sources),'sources are the DGPA files');

-- 端午節 on a Friday is off; 補行上班 on a Saturday is a workday.
select is((select is_off from holidays where date='2026-06-19'),true,'2026-06-19 端午節 off');
select is((select note from holidays where date='2026-06-19'),'端午節','with its note');
select is((select is_off from holidays where date='2025-02-08'),false,'2025-02-08 補行上班');
select is((select is_off from holidays where date='2026-10-27'),false,'an ordinary Tuesday works');

-- holiday_calendar(): only the days that differ from 週六日放假.
select is(holiday_calendar(2025,2027)->'years','[2025,2026,2027]'::jsonb,'covered years');
select ok(holiday_calendar(2026,2026)->'off' ? '2026-06-19','端午節 in off');
select ok(not (holiday_calendar(2026,2026)->'off' ? '2026-06-20'),'a Saturday is not listed');
select is(holiday_calendar(2025,2025)->'work','["2025-02-08"]'::jsonb,'補班 in work');
select is(jsonb_array_length(holiday_calendar(2026,2026)->'off'),16,'115 年 16 weekdays off');
select is(holiday_calendar(2030,2031),'{"years":[],"off":[],"work":[]}'::jsonb,'a year without data is not covered');
select is(holiday_calendar(2000,2100)->'years','[]'::jsonb,'a range wider than 10 years reads nothing');

-- A year missing days is not covered.
delete from holidays where date='2027-03-01';
select is(holiday_calendar(2026,2027)->'years','[2026]'::jsonb,'a half-imported year falls back');
select ok(not (holiday_calendar(2026,2027)->'off' ? '2027-02-08'),'and lists none of its days');

-- Clients read only through holiday_calendar().
set local role anon;
select throws_ok('select * from public.holidays','42501',null,'anon cannot read the table');
select throws_ok('select * from public.holiday_sources','42501',null,'anon cannot read the sources');
select is(jsonb_array_length(public.holiday_calendar(2026,2026)->'years'),1,'anon reads the calendar');
select throws_ok($$insert into public.holidays values ('2030-01-01',true,'')$$,'42501',null,'anon cannot write');
reset role;

select * from finish();
rollback;
