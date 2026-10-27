begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Riders' own edits and votes in the edit history (202610270120, decision
-- 56): the owner's edit through apply_report is 車友更新, every vote is an
-- admin entry, and the app merges a run of votes into one count.
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
-- As the submit-report function calls it: the service role.
create function pg_temp.report(n integer,body jsonb,ip text,device text) returns jsonb language sql as $$
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(device,64),body);
$$;
create function pg_temp.vote(n integer,spot uuid,vote text,ip text) returns jsonb language sql as $$
select pg_temp.report(n,jsonb_build_object('action','vote','spot_id',spot,'vote',vote),ip,ip);
$$;
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '' end,true);
$$;

create temporary table s as select (pg_temp.report(1,jsonb_build_object('action','create','spot',jsonb_build_object(
  'name','車友紀錄測試點','lat',25.31,'lng',121.5,'city','臺北市','space_type','freeMotorcycle',
  'note','原本的備註','condition','{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"free"}'::jsonb)),'a','a')->>'id')::uuid as id;
grant select on s to anon,authenticated;
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s)),0,
  'creating a spot is not a rider event (the creation entry covers it)');

-- Two independent confirmations move the spot to confirmed.
select pg_temp.vote(2,(select id from s),'still_there','b');
select pg_temp.vote(6,(select id from s),'still_there','c');
select is((select status from community_spots where id=(select id from s)),'confirmed','two votes confirm it');
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s) and kind='vote'),2,
  'each vote is recorded');
select is((select after from spot_rider_events where spot_id=(select id from s) and kind='vote' order by id desc limit 1),
  '{"status":"confirmed"}'::jsonb,'the vote that confirmed it carries the status change');
select ok((select before is null and after is null from spot_rider_events where spot_id=(select id from s) and kind='vote' order by id limit 1),
  'a vote that moved nothing carries no change');

-- The owner edits the spot: 車友更新.
select pg_temp.report(1,jsonb_build_object('action','update','spot_id',(select id from s),
  'spot',jsonb_build_object('name','車友紀錄測試點（改）','note','新的備註')),'a','a');
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s) and kind='owner_update'),1,
  'the owner''s edit is recorded once');
select is((select actor from spot_rider_events where kind='owner_update' and spot_id=(select id from s)),pg_temp.uid(1),'by the owner');
select ok((select not (before ? 'user_id' or after ? 'location' or after ? 'last_confirmed_at') from spot_rider_events
  where kind='owner_update' and spot_id=(select id from s)),'only history fields are kept');

-- Then a still-there and a gone vote, and a change of mind.
select pg_temp.vote(2,(select id from s),'still_there','b');
select pg_temp.vote(7,(select id from s),'gone','d');
select pg_temp.vote(6,(select id from s),'still_there','c');

-- An administrator's write is the audit log's, not a rider event.
select pg_temp.act('admin');
update community_spots set note='管理員改的' where id=(select id from s);
select pg_temp.act('');
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s) and kind='owner_update'),1,
  'an administrator''s update is not an owner edit');
-- Nor is a migration's or maintenance write without a JWT.
update community_spots set note='維護' where id=(select id from s);
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s) and kind='owner_update'),1,
  'a write without a JWT is not an owner edit');

-- The administrators' timeline: every vote, with who.
select pg_temp.act('admin');
set local role authenticated;
create temporary table h on commit drop as select admin_spot_history((select id::text from s)) as v;
reset role;
select is((select count(*)::integer from jsonb_array_elements((select v from h)) e where e->>'kind'='vote'),5,
  'five votes, each its own entry');
select is((select e->>'action' from jsonb_array_elements((select v from h)) e where e->>'kind'='vote' limit 1),
  'vote_still_there','newest first: the change of mind');
select is((select e->'changes' from jsonb_array_elements((select v from h)) e where e->>'kind'='owner'),
  '[{"field":"name","after":"車友紀錄測試點（改）","before":"車友紀錄測試點"},{"field":"note","after":"新的備註","before":"原本的備註"},{"field":"status","after":"pending","before":"confirmed"}]'::jsonb,
  'the owner edit with before and after');
select ok((select e ? 'actor_name' from jsonb_array_elements((select v from h)) e where e->>'kind'='owner'),
  'admins see who');

-- The app's: votes merged per run, counts only, no one named.
select pg_temp.act('');
set local role anon;
create temporary table p on commit drop as select spot_history((select id::text from s)) as v;
reset role;
select is((select jsonb_array_length(v) from p),4,'run of votes, owner edit, run of votes, creation');
select is((select v->0->>'kind' from p),'vote','the newest run');
select is((select v->0->'votes' from p),'{"gone":1,"still_there":2}'::jsonb,'two riders still there, one gone');
select is((select v->0->'changes' from p),'[{"field":"status","after":"confirmed"}]'::jsonb,
  'the status the run moved the spot to, which it still holds');
select is((select v->1->>'kind' from p),'owner','the owner''s edit');
select is((select v->1->'changes' from p),'[{"field":"name","after":"車友紀錄測試點（改）"},{"field":"note"}]'::jsonb,
  'public fields only, a value no longer held left out');
select is((select v->2->'votes' from p),'{"gone":0,"still_there":2}'::jsonb,'the first run');
select ok((select not (v::text ~ '("(actor|actor_name|note|report|reason)":|10000000-)') from p),'nobody named');

-- Closures are compared, publicly too (#155 item 30).
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','update_spot','community_spots',s.id::text,
  '{"closure":null}','{"closure":{"reason":"works","since":"2026-10-27"}}','',clock_timestamp() from s;
update community_spots set closure='{"reason":"works","since":"2026-10-27"}' where id=(select id from s);
set local role anon;
select is(spot_history((select id::text from s))->0->'changes',
  '[{"field":"closure","after":{"reason":"works","since":"2026-10-27"}}]'::jsonb,'a closure change shows in the app');
reset role;

-- The events table is not readable directly.
select ok(not has_table_privilege('anon','public.spot_rider_events','SELECT'),'anon cannot read rider events');
select ok(not has_table_privilege('authenticated','public.spot_rider_events','SELECT'),'nor signed-in users');

-- Deleting the spot takes its events.
select pg_temp.report(1,jsonb_build_object('action','delete','spot_id',(select id from s)),'a','a');
select is((select count(*)::integer from spot_rider_events where spot_id=(select id from s)),0,'gone with the spot');

select * from finish();
rollback;
