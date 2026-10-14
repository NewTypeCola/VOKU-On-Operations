-- Private, audited analysis. No new PostgREST or operations-dashboard endpoint.
-- Community IDs are needed transiently for validation, never for analysis output.
insert into voku_metrics.config values
 ('entity_salt',gen_random_uuid()::text||gen_random_uuid()::text),
 ('analysis_salt',gen_random_uuid()::text||gen_random_uuid()::text);
alter table voku_metrics.events add column entity_key text;
update voku_metrics.events set entity_key=voku_metrics.hash(
 (select value from voku_metrics.config where key='entity_salt')||entity_id::text)
 where entity_id is not null and name in ('post_created','comment_created');
drop index voku_metrics.metrics_verified_creation;
alter table voku_metrics.events drop column entity_id;
create unique index metrics_verified_creation on voku_metrics.events(name,entity_key)
 where name in ('post_created','comment_created');

create or replace function voku_metrics.ingest(p_key text,p_payload jsonb,p_context jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 now_at timestamptz:=clock_timestamp(); sid uuid; visitor_key text; actor uuid:=auth.uid();
 is_staff boolean; chosen_audience text; source_name text; device_name text; campaign_name text;
 e jsonb; eid uuid; when_at timestamptz; event_name text; route_name text; record text; entity uuid;
 page_no integer; amount integer; detail_name text; is_sample boolean; n integer:=0; bad integer:=0; duplicates integer:=0;
 rate_count integer; prior voku_metrics.visitors; sess voku_metrics.sessions; p public.community_posts; c public.community_comments;
begin
 if length(p_key)<>64 or not exists(select 1 from voku_metrics.config where key='ingest_hash' and value=voku_metrics.hash(p_key)) then
  raise exception 'metrics_collector_required' using errcode='42501';
 end if;
 if p_payload->>'v'<>'1' or jsonb_typeof(p_payload->'events') is distinct from 'array'
  or jsonb_array_length(p_payload->'events') not between 1 and 30 or octet_length(p_payload::text)>49152 then
  raise exception 'metrics_invalid_batch';
 end if;
 if coalesce(p_context->>'rateKey','') !~ '^[a-f0-9]{64}$' then raise exception 'metrics_invalid_context'; end if;
 insert into voku_metrics.rate_limits as r values(p_context->>'rateKey',date_trunc('minute',now_at),1)
 on conflict(key) do update set bucket=excluded.bucket,count=case when r.bucket=excluded.bucket then r.count+1 else 1 end
 returning count into rate_count;
 if rate_count>120 then return jsonb_build_object('limited',true); end if;
 sid:=(p_payload->>'session')::uuid;
 visitor_key:=voku_metrics.hash((select value from voku_metrics.config where key='identity_salt')||(p_payload->>'visitor')::uuid::text);
 is_staff:=exists(select 1 from voku_private.members where id=actor and role in ('admin','moderator'))
  or exists(select 1 from voku_ops.operators where id=actor);
 select * into prior from voku_metrics.visitors where key=visitor_key;
 is_staff:=is_staff or coalesce(prior.staff,false);
 chosen_audience:=case when coalesce((p_context->>'bot')::boolean,false) then 'bot'
  when p_context->>'environment' is distinct from 'production' or coalesce((p_payload->>'test')::boolean,false) then 'test'
  when is_staff then 'staff' else 'real' end;
 source_name:=case when p_payload->>'source' in ('direct','internal','google','naver','daum','kakao','youtube','instagram','facebook','github','huggingface','other') then p_payload->>'source' else 'other' end;
 campaign_name:=case when p_payload->>'campaign' in ('launch','alumni','qr','newsletter') then p_payload->>'campaign' else 'none' end;
 device_name:=case when p_context->>'device' in ('mobile','tablet','desktop') then p_context->>'device' else 'other' end;
 insert into voku_metrics.visitors values(visitor_key,now_at,now_at,is_staff)
 on conflict(key) do update set last_at=excluded.last_at,staff=voku_metrics.visitors.staff or excluded.staff;
 insert into voku_metrics.sessions values(sid,visitor_key,now_at,now_at,
  prior.first_at is not null and prior.first_at<now_at-interval '30 minutes',chosen_audience,source_name,campaign_name,device_name,
  case when p_context->>'release' ~ '^[a-zA-Z0-9_.-]{1,64}$' then p_context->>'release' else 'unknown' end,
  case when p_context->>'environment'='production' then 'production' else 'preview' end)
 on conflict(id) do nothing;
 select * into sess from voku_metrics.sessions where id=sid for update;
 if sess.visitor<>visitor_key or sess.first_at<now_at-interval '25 hours' then raise exception 'metrics_invalid_session'; end if;
 update voku_metrics.sessions set last_at=now_at,audience=case when chosen_audience<>'real' then chosen_audience else voku_metrics.sessions.audience end where id=sid;
 -- A recognized staff browser stays excluded after logout. Reclassify its still-retained sessions.
 if is_staff then update voku_metrics.sessions set audience='staff' where visitor=visitor_key and audience='real'; end if;
 for e in select value from jsonb_array_elements(p_payload->'events') loop
  begin
   eid:=(e->>'id')::uuid; event_name:=e->>'name'; route_name:=e->>'route';
   when_at:=(e->>'at')::timestamptz;
   if when_at is null or when_at<now_at-interval '24 hours' or when_at>now_at+interval '5 minutes' then raise exception 'invalid_time'; end if;
   if event_name is null or event_name not in ('page_view','engagement','archive_filter','search','read_open','read_tick','read_page','reader_action','reader_compose','post_view','post_created','comment_created','community_action','auth','feature','error','vital','delivery_drop') then raise exception 'invalid_event'; end if;
   if route_name is null or route_name not in ('home','archive','reader','board','news','post','write','search','auth','account','notifications','admin','saved','example','other') then raise exception 'invalid_route'; end if;
   record:=nullif(e->>'record',''); entity:=nullif(e->>'entity','')::uuid;
   page_no:=nullif(e->>'page','')::integer; amount:=coalesce((e->>'value')::integer,0);
   detail_name:=coalesce(e->>'detail','');
   if detail_name<>'' and detail_name not in ('year','term','program','archive','community','all','empty','results','rotate','zoom','fit','jump','resume','share','retry','post_save','post_edit','comment_save','comment_edit','like','bookmark','archive_bookmark','comment_like','report','block','profile','notifications','sign_in','sign_out','banner','menu','time_ring','recent','lcp','cls','inp','ttfb','rpc','network','script','image','catalog','unknown') then raise exception 'invalid_detail'; end if;
   if amount<0 or amount>600000 then raise exception 'invalid_value'; end if;
   if event_name in ('read_tick','engagement') and amount>30000 then raise exception 'invalid_duration'; end if;
   if record is not null and not exists(select 1 from voku_metrics.catalog where id=record and (page_no is null or page_no between 1 and pages)) then raise exception 'invalid_record'; end if;
   if event_name like 'read_%' and record is null then raise exception 'missing_record'; end if;
   is_sample:=route_name='example' or coalesce((e->>'sample')::boolean,false);
   if entity is not null then
    if event_name='comment_created' then
     select * into c from public.community_comments where id=entity;
     if c.id is null or actor is null or c.author_id<>actor or c.created_at<now_at-interval '24 hours' then raise exception 'unverified_creation'; end if;
     select * into p from public.community_posts where id=c.post_id;
     is_sample:=is_sample or c.is_sample;
    else
     select * into p from public.community_posts where id=entity;
     if p.id is null then raise exception 'invalid_post'; end if;
     if event_name='post_created' and (actor is null or p.author_id<>actor or p.created_at<now_at-interval '24 hours') then raise exception 'unverified_creation'; end if;
    end if;
    is_sample:=is_sample or p.sample_batch is not null;
    if event_name in ('post_created','comment_created') then record:=p.record_id; end if;
   elsif event_name in ('post_created','comment_created') then raise exception 'missing_creation';
   end if;
   insert into voku_metrics.events(id,session_id,occurred_at,seq,name,route,record_id,entity_key,sample,page,value,detail)
    values(eid,sid,least(when_at,now_at),greatest(0,least(coalesce((e->>'seq')::integer,0),10000000)),event_name,route_name,record,case when event_name in ('post_created','comment_created') then voku_metrics.hash((select value from voku_metrics.config where key='entity_salt')||entity::text) else null end,is_sample,page_no,amount,detail_name)
    on conflict do nothing;
   if found then n:=n+1; else duplicates:=duplicates+1; end if;
  exception when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow or raise_exception or foreign_key_violation or not_null_violation then
   bad:=bad+1;
  end;
 end loop;
 insert into voku_metrics.health(day,accepted,rejected,duplicate,last_at) values((now_at at time zone 'Asia/Seoul')::date,n,bad,duplicates,now_at)
 on conflict(day) do update set accepted=voku_metrics.health.accepted+excluded.accepted,rejected=voku_metrics.health.rejected+excluded.rejected,
  duplicate=voku_metrics.health.duplicate+excluded.duplicate,last_at=excluded.last_at;
 return jsonb_build_object('accepted',n,'rejected',bad,'duplicate',duplicates);
end $$;


create role voku_usage_reader nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
create role voku_usage_auditor nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
-- Existing trusted DB administration can explicitly SET ROLE; no app user gains access.
grant voku_usage_reader,voku_usage_auditor to postgres;
create schema voku_analysis;
revoke all on schema voku_analysis from public,anon,authenticated,service_role;
alter default privileges in schema voku_analysis revoke execute on functions from public;
grant usage on schema voku_analysis to voku_usage_reader,voku_usage_auditor;

create table voku_analysis.requests(
 id uuid primary key, created_at timestamptz not null default clock_timestamp(),
 db_actor name not null, db_role name not null, purpose text not null, reason text not null,
 from_day date not null, to_day date not null, audience text not null,
 row_count integer not null, truncated boolean not null, sha256 text not null,
 prepared_xid xid8 not null, expires_at timestamptz not null,
 check (purpose in ('archive_journey','returning','participation','data_quality','incident')),
 check (audience in ('real','test','all')),
 check (row_count between 0 and 5000), check (char_length(reason) between 12 and 300)
);
create index analysis_requests_actor_time on voku_analysis.requests(db_actor,created_at);
create index analysis_requests_time on voku_analysis.requests(created_at);
create table voku_analysis.results(
 request_id uuid primary key references voku_analysis.requests(id) on delete cascade,
 payload jsonb not null, expires_at timestamptz not null
);
create index analysis_results_expiry on voku_analysis.results(expires_at);
create table voku_analysis.deliveries(
 id bigint generated always as identity primary key,
 request_id uuid not null references voku_analysis.requests(id) on delete cascade,
 delivered_at timestamptz not null default clock_timestamp(), db_actor name not null
);
create index analysis_deliveries_request on voku_analysis.deliveries(request_id);
alter table voku_analysis.requests enable row level security;
alter table voku_analysis.results enable row level security;
alter table voku_analysis.deliveries enable row level security;
revoke all on all tables in schema voku_analysis from public,anon,authenticated,service_role,voku_usage_reader,voku_usage_auditor;
revoke all on all sequences in schema voku_analysis from public,anon,authenticated,service_role,voku_usage_reader,voku_usage_auditor;
grant select on voku_analysis.requests,voku_analysis.deliveries to voku_usage_auditor;
create policy analysis_audit_read on voku_analysis.requests for select to voku_usage_auditor using (true);
create policy analysis_delivery_audit_read on voku_analysis.deliveries for select to voku_usage_auditor using (true);

create function voku_analysis.require_reader() returns name
language plpgsql security invoker set search_path='' as $$
declare caller name:=coalesce(nullif(current_setting('role',true),'none'),session_user::text)::name;
begin
 if session_user in ('authenticator','anon','authenticated','service_role')
  or caller in ('anon','authenticated','service_role')
  or not pg_has_role(session_user,'voku_usage_reader','MEMBER')
  or not pg_has_role(caller,'voku_usage_reader','MEMBER') then
  raise exception 'analysis_backend_role_required' using errcode='42501';
 end if;
 return caller;
end $$;

-- Prepare a bounded, sanitized snapshot. Only a receipt is returned here.
-- Its purpose/audit record MUST commit before a separate call can read any data.
create function voku_analysis.prepare(
 p_from date,p_to date,p_purpose text,p_reason text,p_audience text default 'real'
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare caller name:=voku_analysis.require_reader(); rid uuid:=gen_random_uuid();
 salt text; result jsonb; count_rows integer; cut boolean; checksum text;
 expiry timestamptz:=clock_timestamp()+interval '10 minutes'; today date:=(now() at time zone 'Asia/Seoul')::date;
begin
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>30 or p_to>today or p_from<today-89 then
  raise exception 'analysis_date_range_max_31_days_within_retention';
 end if;
 if p_purpose is null or p_purpose not in ('archive_journey','returning','participation','data_quality','incident')
  or p_reason is null or char_length(btrim(p_reason)) not between 12 and 300
  or p_reason ~ '[[:cntrl:]]|@|https?://'
  or p_audience is null or p_audience not in ('real','test','all') then
  raise exception 'analysis_purpose_and_nonpersonal_reason_required';
 end if;
 if p_audience<>'real' and p_purpose not in ('data_quality','incident') then
  raise exception 'analysis_nonreal_requires_diagnostic_purpose';
 end if;
 -- Serialize a principal's preparation quota, including concurrent connections.
 perform pg_advisory_xact_lock(hashtextextended('voku_analysis:'||session_user,0));
 if (select count(*) from voku_analysis.requests where db_actor=session_user and created_at>now()-interval '1 hour')>=20 then
  raise exception 'analysis_hourly_request_limit';
 end if;
 delete from voku_analysis.results where expires_at<clock_timestamp();
 select value into strict salt from voku_metrics.config where key='analysis_salt';
 with selected as materialized (
  select e.id,e.session_id,e.occurred_at,e.seq,e.name,e.route,e.record_id,e.page,e.value,e.detail,e.sample,
   s.visitor,s.is_returning,s.source,s.campaign,s.device,s.audience
  from voku_metrics.events e join voku_metrics.sessions s on s.id=e.session_id
  where e.occurred_at>=p_from::timestamp at time zone 'Asia/Seoul'
   and e.occurred_at<(p_to+1)::timestamp at time zone 'Asia/Seoul'
   and (p_audience='all' or (p_audience='test' and s.audience='test')
    or (p_audience='real' and s.audience='real' and not e.sample))
  order by e.occurred_at,e.seq,e.id limit 5001
 ), bounded as materialized (
  select * from selected order by occurred_at,seq,id limit 5000
 ), timed as (
  select *,min(occurred_at) over(partition by session_id) visit_start,
   row_number() over(partition by session_id order by occurred_at,seq,id) event_order
  from bounded
 ), safe as (
  select occurred_at,seq,id,jsonb_build_object(
   'browser','b_'||left(voku_metrics.hash(salt||rid::text||visitor),24),
   'visit','s_'||left(voku_metrics.hash(salt||rid::text||session_id::text),24),
   'day',(occurred_at at time zone 'Asia/Seoul')::date,
   'visitOrder',dense_rank() over(partition by visitor order by visit_start,session_id),
   'eventOrder',event_order,'elapsedSeconds',floor(extract(epoch from occurred_at-visit_start)),
   'event',name,'route',route,'record',record_id,'page',page,'value',value,'detail',detail,
   'returning',is_returning,'source',source,'campaign',campaign,'device',device,'audience',audience,'sample',sample
  ) item from timed
 ) select coalesce(jsonb_agg(item order by occurred_at,seq,id),'[]'::jsonb),
  count(*)::integer,(select count(*)>5000 from selected) into result,count_rows,cut from safe;
 checksum:=voku_metrics.hash(result::text);
 insert into voku_analysis.requests(id,db_actor,db_role,purpose,reason,from_day,to_day,audience,row_count,truncated,sha256,prepared_xid,expires_at)
 values(rid,session_user,caller,p_purpose,btrim(p_reason),p_from,p_to,p_audience,count_rows,cut,checksum,pg_current_xact_id(),expiry);
 insert into voku_analysis.results values(rid,result,expiry);
 return jsonb_build_object('requestId',rid,'rows',count_rows,'truncated',cut,'sha256',checksum,'expiresAt',expiry,
  'next','Commit this request before calling voku_analysis.read_result in a separate transaction.');
end $$;

create function voku_analysis.read_result(p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare caller name:=voku_analysis.require_reader(); req voku_analysis.requests; result jsonb;
begin
 select * into req from voku_analysis.requests where id=p_request and db_actor=session_user;
 if req.id is null then raise exception 'analysis_request_not_found' using errcode='42501'; end if;
 if req.prepared_xid=pg_current_xact_id() then raise exception 'analysis_commit_purpose_before_reading'; end if;
 if req.expires_at<=clock_timestamp() then raise exception 'analysis_result_expired'; end if;
 select payload into result from voku_analysis.results where request_id=req.id and expires_at>clock_timestamp();
 if result is null then raise exception 'analysis_result_unavailable'; end if;
 insert into voku_analysis.deliveries(request_id,db_actor) values(req.id,session_user);
 -- Delivery log also survives a caller rolling back its read transaction.
 -- The durable, previously committed preparation receipt always remains.
 raise log 'voku_analysis_delivery request=% actor=%',req.id,session_user;
 return jsonb_build_object('requestId',req.id,'definition','voku-backend-analysis-v1','timezone','Asia/Seoul',
  'from',req.from_day,'to',req.to_day,'audience',req.audience,'rows',req.row_count,'truncated',req.truncated,
  'sha256',req.sha256,'events',result,'canonicalEvents',result::text,
  'notice','Browser/visit aliases are valid only within this request. Times are relative to the first selected event in each visit. Truncated paths may be incomplete.');
end $$;

create function voku_analysis.my_requests() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform voku_analysis.require_reader();
 return coalesce((select jsonb_agg(to_jsonb(q) order by created_at desc) from
  (select id,created_at,purpose,reason,from_day,to_day,audience,row_count,truncated,expires_at
   from voku_analysis.requests where db_actor=session_user order by created_at desc limit 100) q),'[]'::jsonb);
end $$;

create function voku_analysis.maintain() returns void
language plpgsql security definer set search_path='' as $$
begin
 delete from voku_analysis.results where expires_at<=clock_timestamp();
 delete from voku_analysis.requests where created_at<now()-interval '365 days';
end $$;

-- Erasure must invalidate materialized analysis as well as the source events.
create or replace function voku_metrics.erase(p_key text,p_visitor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare k text;
begin
 if not exists(select 1 from voku_metrics.config where key='ingest_hash' and value=voku_metrics.hash(p_key)) then raise exception 'metrics_collector_required' using errcode='42501'; end if;
 k:=voku_metrics.hash((select value from voku_metrics.config where key='identity_salt')||p_visitor::text);
 delete from voku_analysis.results;
 delete from voku_metrics.sessions where visitor=k;
 delete from voku_metrics.visitors where key=k;
 -- Existing non-identifying daily aggregates and exported reports are retained; no visitor link remains.
end $$;


revoke all on all functions in schema voku_analysis from public,anon,authenticated,service_role,voku_usage_reader,voku_usage_auditor;
grant execute on function voku_analysis.prepare(date,date,text,text,text),voku_analysis.read_result(uuid),voku_analysis.my_requests() to voku_usage_reader;
comment on schema voku_analysis is 'Backend-only audited, minimized analysis. Never add to PostgREST exposed schemas.';
comment on role voku_usage_reader is 'Analysis functions only; no direct user/event tables, no application/API membership. Grant to individually managed DB login principals only.';
