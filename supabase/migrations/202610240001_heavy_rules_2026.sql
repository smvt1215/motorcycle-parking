-- Heavy-bike rules verified against 2026 announcements (assets/rules has the
-- same rows). Only rows still at version 1 change, so an admin's newer edit
-- is never overwritten.
-- Space types a rule opens in named districts only: parkable there, closed
-- elsewhere (an app reading an older row sees no such map and is unchanged).
alter table public.city_rules add column district_space_types jsonb not null default '{}'
  check (jsonb_typeof(district_space_types)='object');
-- New Taipei: citywide paid street bays from 2026-07-01; free bays stay open
-- only in Banqiao and Xindian, whose pilot opened every street bay.
update public.city_rules set
  allowed_space_types='["heavyOnly","car","paidMotorcycle"]'::jsonb,
  conditional_space_types='["offStreet"]'::jsonb,
  district_space_types='{"freeMotorcycle":["板橋區","新店區"]}'::jsonb,
  fee_note='收費機車格比照大型重機專用格，計次每 4 小時 30 元',
  exceptions='2026/7/1 起全市路邊收費機車格開放大型重機。免費機車格僅板橋區、新店區（原試辦區）開放，其他行政區不開放。車身不得超出格線，車身較長可跨 2 格停放。',
  effective_date='2026-07-01',
  source_url='https://www.traffic.ntpc.gov.tw/home.jsp?act=be4f48068b2b0031&dataserno=99345bcf365b8f6ed7a6315705335638&id=54fa46e9e522dde4',
  can_use_two_spaces=true, restriction=null, version=2
where city='新北市' and vehicle='heavy' and version<2;
-- Taoyuan: trial opens every street motorcycle bay, paid and free, from 2026-04-01.
update public.city_rules set
  allowed_space_types='["heavyOnly","car","paidMotorcycle","freeMotorcycle"]'::jsonb,
  conditional_space_types='["offStreet"]'::jsonb,
  fee_note='比照普通機車，依各路段費率與時段',
  exceptions='2026/4/1 起試辦全市路邊機車格（收費與不收費）開放大型重機。以一車一格為原則，車身較長可斜停最多 2 格，車體須完全位於格線內。',
  effective_date='2026-04-01',
  can_use_two_spaces=true, restriction=null, version=2
where city='桃園市' and vehicle='heavy' and version<2;
-- Kaohsiung: street motorcycle bays stay closed; only five public lots trial
-- heavy bikes in scooter bays from 2026-08-01.
update public.city_rules set
  allowed_space_types='["heavyOnly","car"]'::jsonb,
  conditional_space_types='["offStreet"]'::jsonb,
  exceptions='路邊機車格未開放大型重機，請停汽車格或重機專用格。2026/8/1 起僅於 5 處捷運周邊公有停車場試辦停放普通機車格，請依場站公告。',
  effective_date='2026-08-01',
  source_url='https://www.facebook.com/tbkcdream/posts/1370509398601080/',
  restriction=null, version=2
where city='高雄市' and vehicle='heavy' and version<2;
-- Taichung: from 2026-05-01, only street bays and scooter areas marked
-- 「大重機共用」 in four business districts.
update public.city_rules set
  conditional_space_types='["offStreet","paidMotorcycle","freeMotorcycle"]'::jsonb,
  fee_note='比照一般機車費率，依區域與路段計收',
  exceptions='2026/5/1 起於逢甲、勤美、文心秀泰及台中火車站周邊試辦，僅限地面標示「大重機共用」的路邊機車格與機慢車停放區。須依格線停放、不得出線；車身過大請改停汽車格。',
  effective_date='2026-05-01',
  source_url='https://www.traffic.taichung.gov.tw/news/index-1.asp?Parser=9%2C4%2C20%2C%2C%2C%2C21267',
  restriction='signage', version=2
where city='臺中市' and vehicle='heavy' and version<2;
-- pilot_area stays a permitted value: an admin may have kept it on a rule
-- already past version 1, which the updates above leave alone. The app reads
-- it as a generic condition.
