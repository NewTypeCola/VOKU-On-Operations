-- VOKU usage metrics v1. No changes to community authorization or content.
-- Apply after the community migrations through 20261014005024 and ops dashboard.
create schema voku_metrics;
revoke all on schema voku_metrics from public,anon,authenticated;
alter default privileges in schema voku_metrics revoke execute on functions from public;

create table voku_metrics.config(key text primary key,value text not null);
insert into voku_metrics.config values
 ('identity_salt',gen_random_uuid()::text||gen_random_uuid()::text),
 ('started_at',clock_timestamp()::text), ('definition','voku-usage-v1');
-- ingest_hash is provisioned separately; there is no default/open ingestion key.
create table voku_metrics.catalog(
 id text primary key, year smallint not null, term smallint not null,
 title text not null, pages integer not null check(pages>0 and pages<2000)
);
create table voku_metrics.visitors(
 key text primary key, first_at timestamptz not null, last_at timestamptz not null,
 staff boolean not null default false
);
create table voku_metrics.sessions(
 id uuid primary key, visitor text not null, first_at timestamptz not null,
 last_at timestamptz not null, is_returning boolean not null,
 audience text not null check(audience in ('real','staff','test','bot')),
 source text not null, campaign text not null, device text not null,
 release text not null, environment text not null
);
create index metrics_sessions_first on voku_metrics.sessions(first_at);
create index metrics_sessions_visitor on voku_metrics.sessions(visitor);
create table voku_metrics.events(
 id uuid primary key, session_id uuid not null references voku_metrics.sessions(id) on delete cascade,
 received_at timestamptz not null default clock_timestamp(), occurred_at timestamptz not null,
 seq integer not null, name text not null, route text not null,
 record_id text references voku_metrics.catalog(id), entity_id uuid,
 sample boolean not null default false, page integer, value integer not null default 0,
 detail text not null default ''
);
create index metrics_events_time on voku_metrics.events(occurred_at);
create index metrics_events_session_record on voku_metrics.events(session_id,record_id,occurred_at);
create unique index metrics_verified_creation on voku_metrics.events(name,entity_id)
 where name in ('post_created','comment_created');
create table voku_metrics.rate_limits(key text primary key, bucket timestamptz not null, count integer not null);
create table voku_metrics.daily(
 day date not null, audience text not null, payload jsonb not null,
 calculated_at timestamptz not null default now(), primary key(day,audience)
);
create table voku_metrics.snapshots(
 id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(),
 created_by uuid references voku_ops.operators(id) on delete set null,
 payload_text text not null, sha256 text not null
);
create table voku_metrics.health(day date primary key, accepted bigint not null default 0,
 rejected bigint not null default 0, duplicate bigint not null default 0, last_at timestamptz not null default now());
do $$ declare t text; begin
 for t in select tablename from pg_tables where schemaname='voku_metrics' loop
  execute format('alter table voku_metrics.%I enable row level security',t);
 end loop;
end $$;
revoke all on all tables in schema voku_metrics from public,anon,authenticated;

create function voku_metrics.hash(p_text text) returns text language sql immutable set search_path='' as $$
 select encode(sha256(convert_to(p_text,'UTF8')),'hex');
$$;

create function voku_metrics.ingest(p_key text,p_payload jsonb,p_context jsonb) returns jsonb
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
   insert into voku_metrics.events(id,session_id,occurred_at,seq,name,route,record_id,entity_id,sample,page,value,detail)
    values(eid,sid,least(when_at,now_at),greatest(0,least(coalesce((e->>'seq')::integer,0),10000000)),event_name,route_name,record,entity,is_sample,page_no,amount,detail_name)
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
create function public.usage_ingest(p_key text,p_payload jsonb,p_context jsonb) returns jsonb
language sql security invoker set search_path='' as $$ select voku_metrics.ingest(p_key,p_payload,p_context); $$;

-- All metrics below use accepted browser observations. No inferred historical visits.
create function voku_metrics.compute(p_from date,p_to date,p_audience text) returns jsonb
language sql stable set search_path='' as $$
 with e as materialized (
  select e.*,s.visitor,s.is_returning,s.source,s.campaign,s.device,s.audience
  from voku_metrics.events e join voku_metrics.sessions s on s.id=e.session_id
  where e.occurred_at>=p_from::timestamp at time zone 'Asia/Seoul' and e.occurred_at<(p_to+1)::timestamp at time zone 'Asia/Seoul'
   and (p_audience='all' or (s.audience='real' and not e.sample))
 ), visits as (
  select session_id,visitor,bool_or(is_returning) is_returning,min(source) source,min(campaign) campaign,min(device) device,
   count(*) filter(where name='page_view') views,sum(value) filter(where name='engagement') active_ms,
   (array_agg(route order by occurred_at,seq,id) filter(where name='page_view'))[1] entry,
   (array_agg(route order by occurred_at desc,seq desc,id desc) filter(where name='page_view'))[1] exit
  from e group by session_id,visitor
 ), ticks as (
  select *,sum(value) over(partition by session_id,record_id order by occurred_at,seq,id) elapsed from e where name='read_tick'
 ), qualified as (
  select session_id,record_id,min(occurred_at) qualified_at from ticks where elapsed>=30000 group by 1,2
 ), readings as (
  select e.session_id,e.record_id,count(*) filter(where name='read_open') opens,
   coalesce(sum(value) filter(where name='read_tick'),0) ms,
   count(distinct page) filter(where name='read_page') pages,
   max(c.pages) total_pages,max(c.year) as year,max(c.term) term,max(c.title) title,
   q.qualified_at,
   exists(select 1 from e x where x.session_id=e.session_id and x.name='reader_compose' and x.occurred_at>=q.qualified_at) composed,
   exists(select 1 from e x where x.session_id=e.session_id and x.name in ('post_created','comment_created') and x.occurred_at>=q.qualified_at) participated
  from e join voku_metrics.catalog c on c.id=e.record_id
  left join qualified q on q.session_id=e.session_id and q.record_id=e.record_id
  where e.name in ('read_open','read_tick','read_page')
  group by e.session_id,e.record_id,q.qualified_at
 ), pv as (
  select route,session_id,lag(route) over(partition by session_id order by occurred_at,seq,id) previous from e where name='page_view'
 )
 select jsonb_build_object(
  'totals',jsonb_build_object(
   'events',(select count(*) from e),'browsers',(select count(distinct visitor) from e),
   'sessions',(select count(*) from visits),'returningBrowsers',(select count(distinct visitor) from visits where is_returning),
   'pageViews',(select count(*) from e where name='page_view'),
   'activeMs',coalesce((select sum(value) from e where name='engagement'),0),
   'reads',(select count(*) from readings), 'readOpens',coalesce((select sum(opens) from readings),0),
   'qualifiedReads',(select count(*) from readings where qualified_at is not null),
   'completeReads',(select count(*) from readings where qualified_at is not null and pages>=ceil(total_pages*.9)),
   'readMs',coalesce((select sum(ms) from readings),0),
   'readPages',coalesce((select sum(pages) from readings),0),
   'readToCompose',(select count(distinct session_id) from readings where composed),
   'readToCommunity',(select count(distinct session_id) from readings where participated),
   'qualifiedSessions',(select count(distinct session_id) from readings where qualified_at is not null),
   'posts',(select count(*) from e where name='post_created'), 'comments',(select count(*) from e where name='comment_created'),
   'errors',(select count(*) from e where name='error'),
   'shortVisits',(select count(*) from visits where views=1 and coalesce(active_ms,0)<10000)),
  'archive',coalesce((select jsonb_agg(to_jsonb(x) order by x."qualifiedReads" desc,x."readMs" desc,x.id) from (
   select record_id id,max(title) title,max(year) as year,max(term) term,count(*) reads,
    count(*) filter(where qualified_at is not null) "qualifiedReads",
    count(*) filter(where qualified_at is not null and pages>=ceil(total_pages*.9)) "completeReads",
    sum(ms) "readMs",sum(pages) "readPages",count(*) filter(where participated) "toCommunity"
   from readings group by record_id) x),'[]'::jsonb),
  'sources',coalesce((select jsonb_agg(to_jsonb(x) order by x.sessions desc) from (select source,campaign,count(*) sessions,count(*) filter(where is_returning) is_returning from visits group by 1,2) x),'[]'::jsonb),
  'devices',coalesce((select jsonb_agg(to_jsonb(x)) from (select device,count(*) sessions from visits group by 1) x),'[]'::jsonb),
  'routes',coalesce((select jsonb_agg(to_jsonb(x) order by x.views desc) from (
   select route,count(*) filter(where name='page_view') views,coalesce(sum(value) filter(where name='engagement'),0) "activeMs",
    (select count(*) from visits where entry=e.route) entries,(select count(*) from visits where exit=e.route) exits
   from e group by route) x),'[]'::jsonb),
  'transitions',coalesce((select jsonb_agg(to_jsonb(x) order by x.count desc) from (select previous,route,count(*) count from pv where previous is not null group by 1,2) x),'[]'::jsonb),
  'features',coalesce((select jsonb_agg(to_jsonb(x) order by x.count desc) from (select name,detail,count(*) count from e where name in ('search','archive_filter','reader_action','reader_compose','community_action','auth','feature') group by 1,2) x),'[]'::jsonb),
  'errors',coalesce((select jsonb_agg(to_jsonb(x) order by x.count desc) from (select route,detail,count(*) count from e where name='error' group by 1,2) x),'[]'::jsonb),
  'performance',coalesce((select jsonb_agg(to_jsonb(x)) from (select detail metric,count(*) samples,
   percentile_cont(.5) within group(order by value) p50,percentile_cont(.75) within group(order by value) p75,
   percentile_cont(.95) within group(order by value) p95 from e where name='vital' group by detail) x),'[]'::jsonb),
  'excluded',(select jsonb_build_object('staff',count(*) filter(where s.audience='staff'),
   'test',count(*) filter(where s.audience='test'),'bot',count(*) filter(where s.audience='bot'),
   'sample',count(*) filter(where s.audience='real' and x.sample)) from voku_metrics.events x join voku_metrics.sessions s on s.id=x.session_id
   where x.occurred_at>=p_from::timestamp at time zone 'Asia/Seoul' and x.occurred_at<(p_to+1)::timestamp at time zone 'Asia/Seoul')
 );
$$;

create function voku_metrics.maintain() returns void language plpgsql security definer set search_path='' as $$
declare d date; a text; today date:=(now() at time zone 'Asia/Seoul')::date;
begin
 -- Rebuild all retained days: late arrivals, staff recognition and privacy deletion are reflected.
 -- At this project's scale 90 bounded daily groups are small; monitor runtime before growth.
 for d in select distinct (occurred_at at time zone 'Asia/Seoul')::date from voku_metrics.events where occurred_at>=now()-interval '91 days' loop
  foreach a in array array['real','all'] loop
   insert into voku_metrics.daily(day,audience,payload,calculated_at) values(d,a,voku_metrics.compute(d,d,a),now())
   on conflict(day,audience) do update set payload=excluded.payload,calculated_at=excluded.calculated_at;
  end loop;
 end loop;
 delete from voku_metrics.events where occurred_at<(today-90)::timestamp at time zone 'Asia/Seoul';
 delete from voku_metrics.sessions s where last_at<now()-interval '90 days' and not exists(select 1 from voku_metrics.events e where e.session_id=s.id);
 delete from voku_metrics.visitors where last_at<now()-interval '180 days';
 delete from voku_metrics.rate_limits where bucket<now()-interval '2 days';
 delete from voku_metrics.daily where day<today-interval '5 years';
 delete from voku_metrics.snapshots where created_at<now()-interval '5 years';
 delete from voku_metrics.health where day<today-interval '5 years';
 insert into voku_metrics.config values('maintenance_at',now()::text) on conflict(key) do update set value=excluded.value;
end $$;

create function voku_metrics.report(p_from date,p_to date,p_audience text default 'real') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; today date:=(now() at time zone 'Asia/Seoul')::date;
begin
 perform voku_ops.require_operator();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>89 or p_from<today-89 or p_to>today or p_audience not in ('real','all') then raise exception 'metrics_range_90_days'; end if;
 result:=voku_metrics.compute(p_from,p_to,p_audience);
 return result||jsonb_build_object('definition','voku-usage-v1','generatedAt',now(),'from',p_from,'to',p_to,'timezone','Asia/Seoul','audience',p_audience,
  'coverage',jsonb_build_object('startedAt',(select value from voku_metrics.config where key='started_at'),
   'lastReceivedAt',(select max(last_at) from voku_metrics.health),'maintenanceAt',(select value from voku_metrics.config where key='maintenance_at'),
   'rawRetentionDays',90,'visitorRetentionDays',180,'aggregateRetentionYears',5,
   'accepted',coalesce((select sum(accepted) from voku_metrics.health where day between p_from and p_to),0),
   'rejected',coalesce((select sum(rejected) from voku_metrics.health where day between p_from and p_to),0),
   'duplicates',coalesce((select sum(duplicate) from voku_metrics.health where day between p_from and p_to),0),
   'clientDropped',coalesce((select sum(value) from voku_metrics.events where name='delivery_drop' and occurred_at>=p_from::timestamp at time zone 'Asia/Seoul' and occurred_at<(p_to+1)::timestamp at time zone 'Asia/Seoul'),0),
   'storageBytes',(select sum(pg_total_relation_size(format('%I.%I',schemaname,tablename))) from pg_tables where schemaname='voku_metrics')),
  'daily',coalesce((select jsonb_agg(jsonb_build_object('day',d::date,'totals',voku_metrics.compute(d::date,d::date,p_audience)->'totals') order by d)
   from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d),'[]'::jsonb),
  'legacy',jsonb_build_object('notice','기존 DB의 현재 상태 집계입니다. 조회 발생일·열람 시간은 복원할 수 없으며 새 실적과 합산하지 않습니다.',
   'posts',(select count(*) from public.community_posts where created_at>=p_from::timestamp at time zone 'Asia/Seoul' and created_at<(p_to+1)::timestamp at time zone 'Asia/Seoul'),
   'samplePosts',(select count(*) from public.community_posts where sample_batch is not null),
   'staffPosts',(select count(*) from public.community_posts p join voku_private.members m on m.id=p.author_id where m.role<>'member'),
   'comments',(select count(*) from public.community_comments where created_at>=p_from::timestamp at time zone 'Asia/Seoul' and created_at<(p_to+1)::timestamp at time zone 'Asia/Seoul'),
   'cumulativePostViews',(select coalesce(sum(view_count),0) from public.community_posts),
   'archiveBookmarks',(select count(*) from voku_private.archive_bookmarks)));
end $$;
create function public.ops_usage_report(p_from date,p_to date,p_audience text default 'real') returns jsonb
language sql security invoker set search_path='' as $$ select voku_metrics.report(p_from,p_to,p_audience); $$;

create function voku_metrics.trend(p_from date,p_to date,p_audience text default 'real') returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform voku_ops.require_operator();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 or p_from<(now() at time zone 'Asia/Seoul')::date-interval '5 years' or p_audience not in ('real','all') then raise exception 'metrics_trend_range'; end if;
 return jsonb_build_object('definition','voku-usage-v1','from',p_from,'to',p_to,'audience',p_audience,'timezone','Asia/Seoul',
 'notice','일별 집계입니다. 브라우저·세션·회차 수를 날짜 사이에서 더하면 중복되므로 기간 순이용자 수로 사용할 수 없습니다. 오늘 수치는 상세 통계에서 확인하세요.',
 'days',coalesce((select jsonb_agg(jsonb_build_object('day',day,'calculatedAt',calculated_at,'data',payload) order by day) from voku_metrics.daily where day between p_from and p_to and audience=p_audience),'[]'::jsonb));
end $$;
create function public.ops_usage_trend(p_from date,p_to date,p_audience text default 'real') returns jsonb
language sql security invoker set search_path='' as $$ select voku_metrics.trend(p_from,p_to,p_audience); $$;

create function voku_metrics.export(p_from date,p_to date,p_audience text default 'real',p_trend boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); payload text; fingerprint text; sid uuid;
begin
 perform voku_ops.require_operator();
 payload:=(case when p_trend then voku_metrics.trend(p_from,p_to,p_audience) else voku_metrics.report(p_from,p_to,p_audience) end)::text;
 fingerprint:=voku_metrics.hash(payload);
 insert into voku_metrics.snapshots(created_by,payload_text,sha256) values(uid,payload,fingerprint) returning id into sid;
 insert into voku_ops.audit(actor_id,actor_name,action,target_kind,target_id,target_label,reason,before_data,after_data)
 values(uid,(select name from voku_ops.operators where id=uid),'analytics_export','analytics',sid,'이용 분석 보고서','기간 통계 내보내기','{}',jsonb_build_object('from',p_from,'to',p_to,'audience',p_audience,'sha256',fingerprint));
 return jsonb_build_object('id',sid,'createdAt',now(),'sha256',fingerprint,'canonicalPayload',payload);
end $$;
create function public.ops_usage_export(p_from date,p_to date,p_audience text default 'real',p_trend boolean default false) returns jsonb
language sql security invoker set search_path='' as $$ select voku_metrics.export(p_from,p_to,p_audience,p_trend); $$;

-- Privacy erasure for this browser; a collector key plus its random 128-bit browser ID is required.
create function voku_metrics.erase(p_key text,p_visitor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare k text;
begin
 if not exists(select 1 from voku_metrics.config where key='ingest_hash' and value=voku_metrics.hash(p_key)) then raise exception 'metrics_collector_required' using errcode='42501'; end if;
 k:=voku_metrics.hash((select value from voku_metrics.config where key='identity_salt')||p_visitor::text);
 delete from voku_metrics.sessions where visitor=k;
 delete from voku_metrics.visitors where key=k;
 -- Existing non-identifying daily aggregates and exported reports are retained; no visitor link remains.
end $$;
create function public.usage_erase(p_key text,p_visitor uuid) returns void
language sql security invoker set search_path='' as $$ select voku_metrics.erase(p_key,p_visitor); $$;

revoke all on all functions in schema voku_metrics from public,anon,authenticated;
revoke all on function public.usage_ingest(text,jsonb,jsonb),public.usage_erase(text,uuid),
 public.ops_usage_report(date,date,text),public.ops_usage_trend(date,date,text),public.ops_usage_export(date,date,text,boolean) from public,anon,authenticated;
grant usage on schema voku_metrics to anon,authenticated;
grant execute on function voku_metrics.ingest(text,jsonb,jsonb),voku_metrics.erase(text,uuid),public.usage_ingest(text,jsonb,jsonb),public.usage_erase(text,uuid) to anon,authenticated;
grant execute on function voku_metrics.report(date,date,text),voku_metrics.trend(date,date,text),voku_metrics.export(date,date,text,boolean),
 public.ops_usage_report(date,date,text),public.ops_usage_trend(date,date,text),public.ops_usage_export(date,date,text,boolean) to authenticated;
