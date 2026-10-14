-- Separate operator identities and APIs. Existing board roles and RPCs remain intact.
create schema voku_ops;
revoke all on schema voku_ops from public, anon, authenticated;
grant usage on schema voku_ops to authenticated;

create table voku_ops.operators (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  role text not null check (role in ('owner','operator','viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table voku_ops.invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email=lower(btrim(email)) and char_length(email) between 5 and 254 and position('@' in email)>1),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  role text not null check (role in ('owner','operator','viewer')),
  active boolean not null default true,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
create table voku_ops.audit (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id) on delete set null,
  actor_name text not null,
  action text not null,
  target_kind text not null,
  target_id uuid not null,
  target_label text not null,
  reason text not null check (char_length(btrim(reason)) between 2 and 500),
  before_data jsonb not null default '{}',
  after_data jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index ops_audit_time on voku_ops.audit(created_at desc,id desc);
create index ops_audit_actor on voku_ops.audit(actor_id);
create index ops_audit_target on voku_ops.audit(target_kind,target_id,created_at desc);
alter table voku_ops.operators enable row level security;
alter table voku_ops.invitations enable row level security;
alter table voku_ops.audit enable row level security;
revoke all on all tables in schema voku_ops from public,anon,authenticated;

-- The browser's channel only requests registration; the private allowlist grants it.
-- Trusted app metadata is stamped by the database, never by browser-supplied roles.
create function voku_ops.prepare_signup() returns trigger language plpgsql security definer set search_path='' as $$
declare invitation voku_ops.invitations;
begin
  select * into invitation from voku_ops.invitations where email=lower(btrim(new.email)) for update;
  if invitation.id is not null then
    if not invitation.active or invitation.claimed_at is not null then raise exception '운영자 등록이 만료되었거나 취소되었습니다.'; end if;
    new.raw_app_meta_data := coalesce(new.raw_app_meta_data,'{}') || '{"voku_account_type":"operator"}'::jsonb;
  elsif new.raw_user_meta_data->>'account_channel'='voku_operations' or new.raw_app_meta_data->>'voku_account_type'='operator' then
    raise exception '운영자 등록 명단에 없는 이메일입니다.';
  end if;
  return new;
end $$;
create function voku_ops.finish_signup() returns trigger language plpgsql security definer set search_path='' as $$
declare invitation voku_ops.invitations;
begin
  select * into invitation from voku_ops.invitations where email=lower(btrim(new.email)) and active and claimed_at is null for update;
  if invitation.id is null then raise exception '유효한 운영자 등록 정보가 필요합니다.'; end if;
  insert into voku_ops.operators(id,name,role) values(new.id,invitation.name,invitation.role);
  update voku_ops.invitations set claimed_at=now() where id=invitation.id;
  return new;
end $$;
create trigger voku_ops_prepare_signup before insert on auth.users for each row execute function voku_ops.prepare_signup();
drop trigger voku_new_member on auth.users;
create trigger voku_new_member after insert on auth.users for each row
  when (new.raw_app_meta_data->>'voku_account_type' is distinct from 'operator') execute function voku_private.create_member();
create trigger voku_ops_finish_signup after insert on auth.users for each row
  when (new.raw_app_meta_data->>'voku_account_type'='operator') execute function voku_ops.finish_signup();

create function voku_ops.prevent_membership_overlap() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from voku_ops.operators where id=new.id) then raise exception '운영자 계정은 커뮤니티 회원으로 등록할 수 없습니다.'; end if;
  return new;
end $$;
create trigger voku_ops_no_community_profile before insert on public.community_profiles for each row execute function voku_ops.prevent_membership_overlap();

create function voku_ops.require_operator(p_write boolean default false,p_owner boolean default false,p_mfa boolean default true)
returns voku_ops.operators language plpgsql stable security definer set search_path='' as $$
declare actor voku_ops.operators; uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'ops_login_required' using errcode='42501'; end if;
  select o.* into actor from voku_ops.operators o join auth.users u on u.id=o.id
    where o.id=uid and o.active and u.email_confirmed_at is not null
      and u.raw_app_meta_data->>'voku_account_type'='operator'
      and not exists(select 1 from public.community_profiles where id=uid)
      and exists(select 1 from auth.sessions s where s.user_id=uid and s.id::text=auth.jwt()->>'session_id');
  if actor.id is null then raise exception 'ops_access_denied' using errcode='42501'; end if;
  if p_mfa and coalesce(auth.jwt()->>'aal','')<>'aal2' then raise exception 'ops_mfa_required' using errcode='42501'; end if;
  if (p_write and actor.role='viewer') or (p_owner and actor.role<>'owner') then raise exception 'ops_permission_denied' using errcode='42501'; end if;
  return actor;
end $$;

create function voku_ops.me() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(false,false,false);
begin
  return jsonb_build_object('id',actor.id,'name',actor.name,'role',actor.role,'email',(select email from auth.users where id=actor.id),'mfaRequired',coalesce(auth.jwt()->>'aal','')<>'aal2');
end $$;

-- Internal normalized view. No direct grants; checked RPCs are its only client-facing path.
create view voku_ops.entities with (security_invoker=true) as
select 'posts'::text as kind,p.id,p.title as label,p.status,p.category,a.nickname as author,p.created_at,
  p.title||' '||p.body||' '||a.nickname as search,
  jsonb_build_object('id',p.id,'title',p.title,'body',p.body,'status',p.status,'category',p.category,'author',a.nickname,'authorId',p.author_id,
  'createdAt',p.created_at,'updatedAt',p.updated_at,'pinned',p.pinned,'locked',p.locked,'secret',p.is_secret,'views',p.view_count,'recordId',p.record_id,
  'commentCount',(select count(*) from public.community_comments c where c.post_id=p.id and c.status='published'),'version',md5(to_jsonb(p)::text)) as payload
from public.community_posts p join public.community_profiles a on a.id=p.author_id
union all
select 'comments',c.id,left(c.body,100),c.status,p.category,a.nickname,c.created_at,c.body||' '||a.nickname||' '||p.title,
  jsonb_build_object('id',c.id,'title',left(c.body,100),'body',c.body,'status',c.status,'category',p.category,'author',a.nickname,'authorId',c.author_id,'postId',c.post_id,'postTitle',p.title,'createdAt',c.created_at,'updatedAt',c.updated_at,'version',md5(to_jsonb(c)::text))
from public.community_comments c join public.community_posts p on p.id=c.post_id join public.community_profiles a on a.id=c.author_id
union all
select 'reports',r.id,p.title,r.status,r.reason,a.nickname,r.created_at,p.title||' '||r.reason||' '||r.detail||' '||a.nickname,
  jsonb_build_object('id',r.id,'title',p.title,'body',coalesce(c.body,p.body),'status',r.status,'category',r.reason,'author',a.nickname,'targetAuthor',ta.nickname,'postId',r.post_id,'commentId',r.comment_id,'detail',r.detail,'resolution',r.resolution,'createdAt',r.created_at,'resolvedAt',r.resolved_at,'targetStatus',coalesce(c.status,p.status),'version',md5(to_jsonb(r)::text))
from public.community_reports r join public.community_posts p on p.id=r.post_id left join public.community_comments c on c.id=r.comment_id join public.community_profiles a on a.id=r.reporter_id join public.community_profiles ta on ta.id=coalesce(c.author_id,p.author_id)
union all
select 'members',p.id,p.nickname,case when m.suspended_until>now() then 'suspended' when not m.profile_complete then 'incomplete' else 'active' end,m.role,p.nickname,p.created_at,p.nickname||' '||coalesce(m.admission_year::text,'')||' '||coalesce(m.cohort::text,''),
  jsonb_build_object('id',p.id,'title',p.nickname,'author',p.nickname,'status',case when m.suspended_until>now() then 'suspended' when not m.profile_complete then 'incomplete' else 'active' end,'category',m.role,'role',m.role,'admissionYear',m.admission_year,'cohort',m.cohort,'suspendedUntil',m.suspended_until,'body',m.suspension_reason,'createdAt',p.created_at,'version',md5(to_jsonb(m)::text))
from public.community_profiles p join voku_private.members m on m.id=p.id
union all
select 'files',m.id,split_part(m.path,'/',2),coalesce(p.status,'unattached'),coalesce(p.category,''),a.nickname,m.created_at,m.path||' '||a.nickname||' '||coalesce(p.title,''),
  jsonb_build_object('id',m.id,'title',split_part(m.path,'/',2),'path',m.path,'postId',m.post_id,'postTitle',p.title,'status',coalesce(p.status,'unattached'),'category',p.category,'author',a.nickname,'createdAt',m.created_at,'version',md5(to_jsonb(m)::text))
from public.community_media m join public.community_profiles a on a.id=m.author_id left join public.community_posts p on p.id=m.post_id
union all
select 'operators',o.id,o.name,case when o.active then 'active' else 'disabled' end,o.role,u.email,o.created_at,o.name||' '||u.email,
  jsonb_build_object('id',o.id,'title',o.name,'email',u.email,'author',u.email,'role',o.role,'category',o.role,'status',case when o.active then 'active' else 'disabled' end,'createdAt',o.created_at,'version',md5(to_jsonb(o)::text))
from voku_ops.operators o join auth.users u on u.id=o.id
union all
select 'operators',i.id,i.name,case when i.active then 'invited' else 'cancelled' end,i.role,i.email,i.created_at,i.name||' '||i.email,
  jsonb_build_object('id',i.id,'title',i.name,'email',i.email,'author',i.email,'role',i.role,'category',i.role,'status',case when i.active then 'invited' else 'cancelled' end,'createdAt',i.created_at,'version',md5(to_jsonb(i)::text))
from voku_ops.invitations i where i.claimed_at is null
union all
select 'audit',a.id,a.target_label,'recorded',a.action,a.actor_name,a.created_at,a.target_label||' '||a.reason||' '||a.actor_name||' '||a.action,
  jsonb_build_object('id',a.id,'title',a.target_label,'body',a.reason,'status','recorded','category',a.action,'author',a.actor_name,'targetKind',a.target_kind,'targetId',a.target_id,'before',a.before_data,'after',a.after_data,'source','operations','createdAt',a.created_at,'version','')
from voku_ops.audit a
union all
select 'audit',a.id,a.target,'recorded',a.action,p.nickname,a.created_at,a.target||' '||a.reason||' '||p.nickname,
  jsonb_build_object('id',a.id,'title',a.target,'body',a.reason,'status','recorded','category',a.action,'author',p.nickname,'source','community','createdAt',a.created_at,'version','')
from voku_private.audit a join public.community_profiles p on p.id=a.actor_id;
revoke all on voku_ops.entities from public,anon,authenticated;

create function voku_ops.list(p_kind text,p_query jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(false,p_kind='operators'); result jsonb;
  v_page integer:=greatest(1,least(10000,coalesce((p_query->>'page')::integer,1)));
  v_size integer:=greatest(1,least(100,coalesce((p_query->>'pageSize')::integer,20)));
begin
  if p_kind not in ('posts','comments','reports','members','files','operators','audit') then raise exception '잘못된 목록입니다.'; end if;
  with matches as materialized (
    select * from voku_ops.entities e where e.kind=p_kind
      and (actor.role='owner' or e.kind<>'audit' or coalesce(e.payload->>'targetKind','')<>'operators')
      and (coalesce(p_query->>'status','')='' or e.status=p_query->>'status')
      and (coalesce(p_query->>'category','')='' or e.category=p_query->>'category')
      and (coalesce(p_query->>'pinned','false')<>'true' or e.payload->>'pinned'='true')
      and (coalesce(p_query->>'q','')='' or strpos(lower(case p_query->>'field' when 'title' then e.label when 'author' then e.author else e.search end),lower(left(p_query->>'q',200)))>0)
      and (nullif(p_query->>'from','') is null or e.created_at >= (p_query->>'from')::date::timestamp at time zone 'Asia/Seoul')
      and (nullif(p_query->>'to','') is null or e.created_at < ((p_query->>'to')::date+1)::timestamp at time zone 'Asia/Seoul')
  ), page_rows as (select * from matches order by created_at desc,id desc limit v_size offset (v_page-1)*v_size)
  select jsonb_build_object('items',coalesce((select jsonb_agg(payload order by created_at desc,id desc) from page_rows),'[]'),'total',(select count(*) from matches),'page',v_page,'pageSize',v_size) into result;
  return result;
end $$;

create function voku_ops.overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(); result jsonb;
begin
  select jsonb_build_object(
    'pendingReports',(select count(*) from public.community_reports where status='open'),
    'posts',(select count(*) from public.community_posts where status='published'),
    'comments',(select count(*) from public.community_comments where status='published'),
    'members',(select count(*) from voku_private.members),
    'newMembers',(select count(*) from public.community_profiles where created_at >= date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),
    'hiddenPosts',(select count(*) from public.community_posts where status='hidden'),
    'suspendedMembers',(select count(*) from voku_private.members where suspended_until>now()),
    'pinnedPosts',(select count(*) from public.community_posts where pinned and status='published'),
    'reports',(voku_ops.list('reports','{"status":"open","pageSize":5}'))->'items',
    'recentPosts',(voku_ops.list('posts','{"status":"published","pageSize":5}'))->'items',
    'audit',(voku_ops.list('audit','{"pageSize":5}'))->'items',
    'daily',(select jsonb_agg(jsonb_build_object('date',d::date,'posts',(select count(*) from public.community_posts where (created_at at time zone 'Asia/Seoul')::date=d::date),'comments',(select count(*) from public.community_comments where (created_at at time zone 'Asia/Seoul')::date=d::date)) order by d) from generate_series((now() at time zone 'Asia/Seoul')::date-6,(now() at time zone 'Asia/Seoul')::date,interval '1 day')d)
  ) into result;
  return result;
end $$;

create function voku_ops.detail(p_kind text,p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(false,p_kind='operators'); item jsonb; history jsonb; photos jsonb;
begin
  if p_kind not in ('posts','comments','reports','members','files','operators','audit') then raise exception '잘못된 항목입니다.'; end if;
  select payload into item from voku_ops.entities where kind=p_kind and id=p_id;
  if item is null then raise exception '항목이 없거나 삭제되었습니다.'; end if;
  if p_kind='audit' and item->>'targetKind'='operators' then perform voku_ops.require_operator(false,true); end if;
  select coalesce(jsonb_agg(x.payload order by x.created_at desc),'[]') into history from (select e.payload,e.created_at from voku_ops.entities e where e.kind='audit' and ((e.payload->>'targetId'=p_id::text and e.payload->>'targetKind'=p_kind) or (e.payload->>'source'='community' and e.label=p_id::text)) order by e.created_at desc limit 20)x;
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'path',m.path) order by m.position),'[]') into photos from public.community_media m where m.post_id=case when p_kind='posts' then p_id else nullif(item->>'postId','')::uuid end;
  return jsonb_build_object('item',item,'history',history,'photos',photos);
end $$;

create function voku_ops.mutate(p_kind text,p_action text,p_targets jsonb,p_reason text,p_value jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(true,p_kind='operators'); t jsonb; old jsonb; fresh jsonb;
  target uuid; p public.community_posts; c public.community_comments; r public.community_reports; m voku_private.members; o voku_ops.operators; i voku_ops.invitations; n integer:=0;
begin
  p_reason:=btrim(coalesce(p_reason,''));
  if char_length(p_reason) not between 2 and 500 then raise exception '처리 사유를 2~500자로 입력해 주세요.'; end if;
  if p_kind is null or p_action is null or not ((p_kind in ('posts','comments') and p_action in ('hide','restore')) or (p_kind='posts' and p_action in ('pin','unpin','lock','unlock')) or (p_kind='reports' and p_action in ('resolve_hide','dismiss')) or (p_kind='members' and p_action in ('suspend','unsuspend')) or (p_kind='operators' and p_action in ('role','disable','enable','cancel_invite'))) then raise exception '허용되지 않은 작업입니다.'; end if;
  if jsonb_typeof(p_targets) is distinct from 'array' or jsonb_array_length(p_targets) not between 1 and 50 then raise exception '한 번에 1~50개 항목을 선택해 주세요.'; end if;
  if (select count(distinct x->>'id') from jsonb_array_elements(p_targets)x)<>jsonb_array_length(p_targets) then raise exception '중복된 항목입니다.'; end if;
  if p_kind='operators' then perform pg_advisory_xact_lock(785645901); end if;
  for t in select value from jsonb_array_elements(p_targets) order by value->>'id' loop
    target:=(t->>'id')::uuid;
    if p_kind='posts' then select * into p from public.community_posts where id=target for update;
    elsif p_kind='comments' then select * into c from public.community_comments where id=target for update;
    elsif p_kind='reports' then select * into r from public.community_reports where id=target for update;
    elsif p_kind='members' then select * into m from voku_private.members where id=target for update;
    elsif p_action='cancel_invite' then select * into i from voku_ops.invitations where id=target and claimed_at is null for update;
    else select * into o from voku_ops.operators where id=target for update;
    end if;
    select payload into old from voku_ops.entities where kind=p_kind and id=target;
    if old is null or nullif(t->>'version','') is null or old->>'version' is distinct from t->>'version' then raise exception 'ops_conflict'; end if;
    if p_kind='posts' then
      if p.status='deleted' then raise exception '작성자가 삭제한 글은 변경할 수 없습니다.'; end if;
      if p_action='pin' and (p.is_secret or p.status<>'published') then raise exception '공개된 일반 글만 공지로 고정할 수 있습니다.'; end if;
      update public.community_posts set status=case p_action when 'hide' then 'hidden' when 'restore' then 'published' else status end,
        pinned=case p_action when 'pin' then true when 'unpin' then false else pinned end,
        locked=case p_action when 'lock' then true when 'unlock' then false else locked end,updated_at=clock_timestamp() where id=target;
    elsif p_kind='comments' then
      if c.status='deleted' then raise exception '작성자가 삭제한 댓글은 변경할 수 없습니다.'; end if;
      update public.community_comments set status=case p_action when 'hide' then 'hidden' else 'published' end,updated_at=clock_timestamp() where id=target;
    elsif p_kind='reports' then
      if r.status<>'open' then raise exception '이미 처리된 신고입니다.'; end if;
      if p_action='resolve_hide' then
        if r.comment_id is not null then update public.community_comments set status='hidden',updated_at=clock_timestamp() where id=r.comment_id and status='published';
        else update public.community_posts set status='hidden',updated_at=clock_timestamp() where id=r.post_id and status='published'; end if;
      end if;
      -- resolved_by references community_profiles. Operators are deliberately not community members.
      -- The separate immutable audit identifies the actual operator; the existing FK is preserved.
      update public.community_reports set status=case p_action when 'dismiss' then 'dismissed' else 'resolved' end,resolution=p_reason,resolved_at=clock_timestamp(),resolved_by=null where id=target;
    elsif p_kind='members' then
      if m.role<>'member' then raise exception '기존 게시판 관리자와 운영진의 권한은 이 화면에서 변경하지 않습니다.'; end if;
      if p_action='suspend' and coalesce((p_value->>'days')::integer,0) not in (1,7,30,365) then raise exception '제한 기간을 선택해 주세요.'; end if;
      update voku_private.members set suspended_until=case when p_action='suspend' then now()+make_interval(days=>(p_value->>'days')::integer) else null end,suspension_reason=case when p_action='suspend' then p_reason else '' end where id=target;
    else
      if target=actor.id then raise exception '자신의 운영 권한은 변경할 수 없습니다.'; end if;
      if p_action='cancel_invite' then
        if i.id is null then raise exception '등록 완료된 계정은 등록 취소 대신 접근을 중지해 주세요.'; end if;
        update voku_ops.invitations set active=false where id=target;
      else
        if o.id is null then raise exception '등록 완료된 운영자만 변경할 수 있습니다.'; end if;
        if p_action='role' and coalesce(p_value->>'role','') not in ('owner','operator','viewer') then raise exception '역할을 선택해 주세요.'; end if;
        if o.active and o.role='owner' and (p_action='disable' or (p_action='role' and p_value->>'role'<>'owner')) and (select count(*) from voku_ops.operators where active and role='owner')<=1 then raise exception '마지막 최고운영자를 해제할 수 없습니다.'; end if;
        update voku_ops.operators set role=case when p_action='role' then p_value->>'role' else role end,active=case p_action when 'disable' then false when 'enable' then true else active end,updated_at=clock_timestamp() where id=target;
      end if;
    end if;
    select payload into fresh from voku_ops.entities where kind=p_kind and id=target;
    insert into voku_ops.audit(actor_id,actor_name,action,target_kind,target_id,target_label,reason,before_data,after_data)
      values(actor.id,actor.name,p_action,p_kind,target,old->>'title',p_reason,old-'body'-'detail',fresh-'body'-'detail');
    n:=n+1;
  end loop;
  return jsonb_build_object('changed',n);
end $$;

create function voku_ops.invite(p_email text,p_name text,p_role text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor voku_ops.operators:=voku_ops.require_operator(true,true); iid uuid;
begin
  p_email:=lower(btrim(coalesce(p_email,''))); p_name:=btrim(coalesce(p_name,'')); p_reason:=btrim(coalesce(p_reason,''));
  if p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or char_length(p_email)>254 then raise exception '이메일 주소를 확인해 주세요.'; end if;
  if char_length(p_name) not between 1 and 40 or coalesce(p_role,'') not in ('owner','operator','viewer') or char_length(p_reason) not between 2 and 500 then raise exception '이름, 역할, 등록 사유를 확인해 주세요.'; end if;
  if exists(select 1 from auth.users where lower(email)=p_email) then raise exception '기존 회원 이메일은 사용할 수 없습니다. 운영자 전용 이메일을 입력해 주세요.'; end if;
  insert into voku_ops.invitations(email,name,role) values(p_email,p_name,p_role) returning id into iid;
  insert into voku_ops.audit(actor_id,actor_name,action,target_kind,target_id,target_label,reason,after_data) values(actor.id,actor.name,'invite','operators',iid,p_name,p_reason,jsonb_build_object('email',p_email,'role',p_role));
  return jsonb_build_object('id',iid);
end $$;

create function voku_ops.media_readable(p_path text) returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  perform voku_ops.require_operator();
  return exists(select 1 from public.community_media where path=p_path and post_id is not null);
exception when insufficient_privilege then return false;
end $$;
create policy ops_photo_read on storage.objects for select to authenticated
  using(bucket_id='community-photos' and voku_ops.media_readable(name));

-- Exposed wrappers have no elevated privileges. Internal entry points all check the actor.
create function public.ops_me() returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.me() $$;
create function public.ops_overview() returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.overview() $$;
create function public.ops_list(p_kind text,p_query jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.list(p_kind,p_query) $$;
create function public.ops_detail(p_kind text,p_id uuid) returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.detail(p_kind,p_id) $$;
create function public.ops_mutate(p_kind text,p_action text,p_targets jsonb,p_reason text,p_value jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.mutate(p_kind,p_action,p_targets,p_reason,p_value) $$;
create function public.ops_invite(p_email text,p_name text,p_role text,p_reason text) returns jsonb language sql security invoker set search_path='' as $$ select voku_ops.invite(p_email,p_name,p_role,p_reason) $$;
revoke all on all functions in schema voku_ops from public,anon,authenticated;
grant execute on function voku_ops.me(),voku_ops.overview(),voku_ops.list(text,jsonb),voku_ops.detail(text,uuid),voku_ops.mutate(text,text,jsonb,text,jsonb),voku_ops.invite(text,text,text,text),voku_ops.media_readable(text) to authenticated;
revoke all on function public.ops_me(),public.ops_overview(),public.ops_list(text,jsonb),public.ops_detail(text,uuid),public.ops_mutate(text,text,jsonb,text,jsonb),public.ops_invite(text,text,text,text) from public,anon,authenticated;
grant execute on function public.ops_me(),public.ops_overview(),public.ops_list(text,jsonb),public.ops_detail(text,uuid),public.ops_mutate(text,text,jsonb,text,jsonb),public.ops_invite(text,text,text,text) to authenticated;
