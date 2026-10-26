begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Precheck holds and rider evidence (202610270050): flags and links stay on
-- the case, and a held spot takes one more confirmation while its case is open.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.report(n integer,body jsonb,ip text,device text) returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(device,64),body);
$$;
create function pg_temp.spot(name text,lat float8,extra jsonb default '{}') returns jsonb language sql as $$
select jsonb_build_object('action','create','spot',jsonb_build_object('name',name,'lat',lat,'lng',121.5,
  'city','臺北市','space_type','freeMotorcycle','condition',
  '{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"free"}'::jsonb))||extra;
$$;

create temporary table held as select (pg_temp.report(1,pg_temp.spot('普大共用免費格',25.1,
  '{"risk_flags":["share_free_needs_basis"],"evidence_url":"https://pma.gov.taipei/notice"}'),'a','a')->>'id')::uuid as id;
select is((select risk_flags from moderation_queue where source_id=(select id::text from held)),
  array['share_free_needs_basis'],'a held new spot opens a case with its flags');
select is((select evidence_url from moderation_queue where source_id=(select id::text from held)),
  'https://pma.gov.taipei/notice','the case keeps the notice link');
select is((select reporter_id from moderation_queue where source_id=(select id::text from held)),
  pg_temp.uid(1),'the case names the reporter');
select ok(not exists(select 1 from community_spots where id=(select id from held)
  and (to_jsonb(community_spots)?'risk_flags' or to_jsonb(community_spots)?'evidence_url')),
  'the spot itself carries neither');

select pg_temp.report(2,jsonb_build_object('action','vote','spot_id',(select id from held),'vote','still_there'),'b','b');
select pg_temp.report(6,jsonb_build_object('action','vote','spot_id',(select id from held),'vote','still_there'),'c','c');
select is((select status from community_spots where id=(select id from held)),'pending',
  'two confirmations do not confirm a held spot');
select pg_temp.report(7,jsonb_build_object('action','vote','spot_id',(select id from held),'vote','still_there'),'d','d');
select is((select status from community_spots where id=(select id from held)),'confirmed',
  'a third independent confirmation does');

-- Once an admin resolves the case, the usual two suffice.
create temporary table resolved as select (pg_temp.report(1,pg_temp.spot('已審免費格',25.2,
  '{"risk_flags":["share_free_needs_basis"]}'),'a','a')->>'id')::uuid as id;
update moderation_queue set status='closed',resolved_at=now() where source_id=(select id::text from resolved);
select pg_temp.report(2,jsonb_build_object('action','vote','spot_id',(select id from resolved),'vote','still_there'),'b','b');
select pg_temp.report(6,jsonb_build_object('action','vote','spot_id',(select id from resolved),'vote','still_there'),'c','c');
select is((select status from community_spots where id=(select id from resolved)),'confirmed',
  'a resolved hold no longer raises the threshold');

-- A link alone opens a case but no stricter threshold; a plain spot opens none.
create temporary table linked as select (pg_temp.report(1,pg_temp.spot('附連結免費格',25.3,
  '{"evidence_url":"https://pma.gov.taipei/x"}'),'a','a')->>'id')::uuid as id;
select is((select cardinality(risk_flags) from moderation_queue where source_id=(select id::text from linked)),0,
  'a link without a hold opens an unflagged case');
select pg_temp.report(2,jsonb_build_object('action','vote','spot_id',(select id from linked),'vote','still_there'),'b','b');
select pg_temp.report(6,jsonb_build_object('action','vote','spot_id',(select id from linked),'vote','still_there'),'c','c');
select is((select status from community_spots where id=(select id from linked)),'confirmed',
  'an unflagged case keeps the usual two confirmations');
create temporary table plain as select (pg_temp.report(1,pg_temp.spot('一般免費格',25.4),'a','a')->>'id')::uuid as id;
select is((select count(*)::integer from moderation_queue where source_id=(select id::text from plain)),0,
  'a spot with neither opens no case');

-- Suggestions keep both on their own case.
select pg_temp.report(2,jsonb_build_object('action','flag','source_id',(select id::text from plain),
  'reason','格位類型','field','space_type','evidence_url','https://pma.gov.taipei/y',
  'risk_flags',jsonb_build_array('share_free_needs_basis'),
  'proposed',jsonb_build_object('space_type','freeMotorcycle')),'b','b');
select is((select (risk_flags,evidence_url)::text from moderation_queue
  where source_id=(select id::text from plain) and reason='格位類型'),
  '({share_free_needs_basis},https://pma.gov.taipei/y)','a held suggestion keeps its flags and link');
-- A held suggestion is not applied yet: it does not raise the spot's threshold.
select pg_temp.report(6,jsonb_build_object('action','vote','spot_id',(select id from plain),'vote','still_there'),'c','c');
select pg_temp.report(7,jsonb_build_object('action','vote','spot_id',(select id from plain),'vote','still_there'),'d','d');
select is((select status from community_spots where id=(select id from plain)),'confirmed',
  'an open held suggestion leaves the usual two confirmations');

select throws_ok($$insert into moderation_queue(source_id,reason,evidence_url) values('x','y','http://a.tw')$$,
  '23514',null,'only https links are kept');
select * from finish();
rollback;
