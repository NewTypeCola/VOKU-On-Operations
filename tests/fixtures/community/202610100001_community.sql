-- VOKU On community. Apply once with the Supabase SQL editor or CLI.
-- Authenticated writes go through checked RPCs, never browser-supplied role fields.
begin;
create schema if not exists voku_private;
revoke all on schema voku_private from public, anon, authenticated;

create table public.community_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 2 and 16),
  created_at timestamptz not null default now()
);
create unique index community_nickname_unique on public.community_profiles(lower(nickname));
create table voku_private.members (
  id uuid primary key references public.community_profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('member','moderator','admin')),
  suspended_until timestamptz,
  suspension_reason text not null default ''
);
create table public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.community_profiles(id),
  category text not null check (category in ('일상','추억','음악','질문','동문소식')),
  title text not null check (char_length(btrim(title)) between 1 and 100),
  body text not null check (char_length(btrim(body)) between 1 and 10000),
  record_id text check (record_id is null or record_id ~ '^voku_[a-z0-9_]{1,175}$'),
  pinned boolean not null default false,
  locked boolean not null default false,
  status text not null default 'published' check (status in ('published','hidden','deleted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index community_posts_list on public.community_posts(status, created_at desc);
create table public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id),
  author_id uuid not null references public.community_profiles(id),
  parent_id uuid references public.community_comments(id),
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  status text not null default 'published' check (status in ('published','hidden','deleted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index community_comments_post on public.community_comments(post_id,created_at);
create table public.community_likes (
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  post_id uuid not null references public.community_posts(id),
  primary key(user_id,post_id)
);
create index community_likes_post on public.community_likes(post_id);
create table public.community_bookmarks (
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  post_id uuid not null references public.community_posts(id),
  created_at timestamptz not null default now(),
  primary key(user_id,post_id)
);
create table public.community_blocks (
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  target_id uuid not null references public.community_profiles(id) on delete cascade,
  check (user_id <> target_id), primary key(user_id,target_id)
);
create table public.community_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.community_profiles(id),
  post_id uuid not null references public.community_posts(id),
  comment_id uuid references public.community_comments(id),
  reason text not null check (reason in ('광고·도배','욕설·비방','개인정보 노출','부적절한 내용','기타')),
  detail text not null default '' check (char_length(detail)<=1000),
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  resolution text not null default '',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.community_profiles(id)
);
create unique index community_report_once on public.community_reports(reporter_id,post_id,coalesce(comment_id,'00000000-0000-0000-0000-000000000000'::uuid));
create table public.community_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  post_id uuid not null references public.community_posts(id),
  text text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index community_notifications_user on public.community_notifications(user_id,created_at desc);
create table voku_private.audit (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.community_profiles(id),
  action text not null, target text not null, reason text not null default '',
  created_at timestamptz not null default now()
);
create table voku_private.rate_limits (
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  action text not null, last_at timestamptz not null,
  primary key(user_id,action)
);

create function voku_private.create_member() returns trigger language plpgsql security definer set search_path='' as $$
declare n text := btrim(coalesce(new.raw_user_meta_data->>'nickname',''));
begin
  if n !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
  insert into public.community_profiles(id,nickname) values(new.id,n);
  insert into voku_private.members(id) values(new.id); -- ignores any supplied role
  return new;
end $$;
create trigger voku_new_member after insert on auth.users for each row execute function voku_private.create_member();

create function voku_private.is_staff() returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from voku_private.members where id=auth.uid() and role in ('admin','moderator') and (suspended_until is null or suspended_until<=now()));
$$;
create function voku_private.require_member() returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception '로그인과 이메일 확인이 필요합니다.'; end if;
  if not exists(select 1 from voku_private.members where id=uid) then raise exception '회원 정보를 찾을 수 없습니다.'; end if;
  if exists(select 1 from voku_private.members where id=uid and suspended_until>now()) then raise exception '이용이 제한된 계정입니다. 내 정보에서 사유를 확인해 주세요.'; end if;
  return uid;
end $$;
create function voku_private.throttle(uid uuid, kind text, seconds integer) returns void language plpgsql security definer set search_path='' as $$
declare last_time timestamptz;
begin
  insert into voku_private.rate_limits values(uid,kind,'epoch') on conflict do nothing;
  select last_at into last_time from voku_private.rate_limits where user_id=uid and action=kind for update;
  if last_time > clock_timestamp()-make_interval(secs=>seconds) then raise exception '잠시 후 다시 시도해 주세요.'; end if;
  update voku_private.rate_limits set last_at=clock_timestamp() where user_id=uid and action=kind;
end $$;
create function voku_private.profile_json(uid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p.id,'nickname',p.nickname,'joinedAt',p.created_at,'role',m.role,'suspendedUntil',m.suspended_until,'suspensionReason',m.suspension_reason)
  from public.community_profiles p join voku_private.members m using(id) where p.id=uid;
$$;
create function voku_private.post_json(pid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p.id,'authorId',p.author_id,'author',a.nickname,'authorRole',m.role,'title',p.title,'body',p.body,'category',p.category,'recordId',p.record_id,'date',p.created_at,'updatedAt',p.updated_at,'pinned',p.pinned,'locked',p.locked,'status',p.status,'views',0,
    'likes',(select count(*) from public.community_likes where post_id=p.id),
    'commentCount',(select count(*) from public.community_comments where post_id=p.id and status='published'),
    'liked',exists(select 1 from public.community_likes where post_id=p.id and user_id=auth.uid()),
    'bookmarked',exists(select 1 from public.community_bookmarks where post_id=p.id and user_id=auth.uid()))
  from public.community_posts p join public.community_profiles a on a.id=p.author_id join voku_private.members m on m.id=p.author_id where p.id=pid;
$$;
create function voku_private.comment_json(cid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',c.id,'postId',c.post_id,'authorId',c.author_id,'author',a.nickname,'authorRole',m.role,'parentId',c.parent_id,'body',case when c.status='published' then c.body when c.status='hidden' then '운영진이 숨긴 댓글입니다.' else '삭제된 댓글입니다.' end,'status',c.status,'date',c.created_at)
  from public.community_comments c join public.community_profiles a on a.id=c.author_id join voku_private.members m on m.id=c.author_id where c.id=cid;
$$;
create function voku_private.report_json(rid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',r.id,'postId',r.post_id,'commentId',r.comment_id,'targetAuthorId',coalesce(c.author_id,p.author_id),'title',p.title,'body',coalesce(c.body,p.body),'reporter',a.nickname,'reason',r.reason,'detail',r.detail,'status',r.status,'date',r.created_at,'resolution',r.resolution)
  from public.community_reports r join public.community_posts p on p.id=r.post_id left join public.community_comments c on c.id=r.comment_id join public.community_profiles a on a.id=r.reporter_id where r.id=rid;
$$;

-- RLS is defense in depth. Only public rows can be selected directly;
-- all mutations below have explicit ownership, status and role checks.
alter table public.community_profiles enable row level security;
alter table public.community_posts enable row level security;
alter table public.community_comments enable row level security;
alter table public.community_likes enable row level security;
alter table public.community_bookmarks enable row level security;
alter table public.community_blocks enable row level security;
alter table public.community_reports enable row level security;
alter table public.community_notifications enable row level security;
create policy profiles_public on public.community_profiles for select using(true);
create policy posts_public on public.community_posts for select using(status='published');
create policy comments_public on public.community_comments for select using(status='published' and exists(select 1 from public.community_posts p where p.id=post_id and p.status='published'));
create policy likes_own on public.community_likes for select using(user_id=auth.uid());
create policy bookmarks_own on public.community_bookmarks for select using(user_id=auth.uid());
create policy blocks_own on public.community_blocks for select using(user_id=auth.uid());
create policy reports_own on public.community_reports for select using(reporter_id=auth.uid());
create policy notifications_own on public.community_notifications for select using(user_id=auth.uid());
revoke all on public.community_profiles, public.community_posts, public.community_comments, public.community_likes, public.community_bookmarks, public.community_blocks, public.community_reports, public.community_notifications from anon, authenticated;
grant select on public.community_profiles, public.community_posts, public.community_comments, public.community_likes, public.community_bookmarks, public.community_blocks, public.community_reports, public.community_notifications to anon, authenticated;

create function public.community_feed(p_category text default '',p_sort text default 'latest',p_query text default '',p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; notices jsonb; total integer;
begin
  if p_page<1 or p_page>5000 or char_length(p_query)>100 then raise exception '검색 조건을 확인해 주세요.'; end if;
  with filtered as (select p.*,(select count(*) from public.community_likes l where l.post_id=p.id) votes from public.community_posts p where p.status='published'
    and (p.pinned or not exists(select 1 from public.community_blocks b where b.user_id=auth.uid() and b.target_id=p.author_id))
    and (not p.pinned or p_category='공지' or p_query<>'')
    and (p_category='' or p_category='전체' or (p_category='공지' and p.pinned) or (p_category='자료 이야기' and p.record_id is not null) or (p_category='자유글' and p.category='일상' and p.record_id is null) or p.category=p_category)
    and (p_query='' or strpos(lower(p.title||' '||p.body||' '||(select nickname from public.community_profiles where id=p.author_id)),lower(p_query))>0))
  select count(*) into total from filtered;
  with filtered as (select p.*,(select count(*) from public.community_likes l where l.post_id=p.id) votes from public.community_posts p where p.status='published'
    and (p.pinned or not exists(select 1 from public.community_blocks b where b.user_id=auth.uid() and b.target_id=p.author_id))
    and (not p.pinned or p_category='공지' or p_query<>'')
    and (p_category='' or p_category='전체' or (p_category='공지' and p.pinned) or (p_category='자료 이야기' and p.record_id is not null) or (p_category='자유글' and p.category='일상' and p.record_id is null) or p.category=p_category)
    and (p_query='' or strpos(lower(p.title||' '||p.body||' '||(select nickname from public.community_profiles where id=p.author_id)),lower(p_query))>0)),
  selected as (select * from filtered order by case when p_sort='popular' then votes else 0 end desc,created_at desc,id desc limit 20 offset (p_page-1)*20)
  select coalesce(jsonb_agg(voku_private.post_json(id) order by case when p_sort='popular' then votes else 0 end desc,created_at desc,id desc),'[]') into result from selected;
  select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc),'[]') into notices from (select id,created_at from public.community_posts where status='published' and pinned order by created_at desc limit 3) p;
  return jsonb_build_object('posts',result,'notices',notices,'total',total);
end $$;
create function public.community_post(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p public.community_posts; thread jsonb;
begin
  select * into p from public.community_posts where id=p_id;
  if p.id is null or p.status='deleted' or (p.status<>'published' and not voku_private.is_staff()) then raise exception '글을 찾을 수 없거나 공개되지 않은 글입니다.'; end if;
  select coalesce(jsonb_agg(voku_private.comment_json(c.id) order by c.created_at),'[]') into thread from public.community_comments c where c.post_id=p_id and not exists(select 1 from public.community_blocks b where b.user_id=auth.uid() and b.target_id=c.author_id);
  return jsonb_build_object('post',voku_private.post_json(p_id),'comments',thread);
end $$;
create function public.community_account() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  return jsonb_build_object('profile',voku_private.profile_json(uid),
  'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_posts where author_id=uid and status='published' order by created_at desc limit 100) p),
  'comments',(select coalesce(jsonb_agg(voku_private.comment_json(id) order by created_at desc),'[]') from (select c.id,c.created_at from public.community_comments c join public.community_posts p on p.id=c.post_id where c.author_id=uid and c.status='published' and p.status='published' order by c.created_at desc limit 100) c),
  'saved',(select coalesce(jsonb_agg(voku_private.post_json(p.id) order by b.created_at desc),'[]') from public.community_bookmarks b join public.community_posts p on p.id=b.post_id where b.user_id=uid and p.status='published'),
  'notifications',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'postId',post_id,'text',text,'date',created_at,'read',is_read) order by created_at desc),'[]') from (select * from public.community_notifications where user_id=uid order by created_at desc limit 50) n),
  'blocked',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname)),'[]') from public.community_blocks b join public.community_profiles p on p.id=b.target_id where b.user_id=uid),
  'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'postId',r.post_id,'commentId',r.comment_id,'title',p.title,'body','','reporter','','reason',r.reason,'detail',r.detail,'status',r.status,'date',r.created_at,'resolution',r.resolution,'targetAuthorId',p.author_id) order by r.created_at desc),'[]') from public.community_reports r join public.community_posts p on p.id=r.post_id where r.reporter_id=uid));
end $$;
create function public.community_admin(p_query text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not voku_private.is_staff() then raise exception '운영 권한이 필요합니다.'; end if;
  return jsonb_build_object(
    'reports',(select coalesce(jsonb_agg(voku_private.report_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_reports order by (status='open') desc,created_at desc limit 100) r),
    'members',(select coalesce(jsonb_agg(voku_private.profile_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_profiles where strpos(lower(nickname),lower(p_query))>0 order by created_at desc limit 100) m),
    'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_posts where status<>'deleted' and strpos(lower(title),lower(p_query))>0 order by created_at desc limit 100) p),
    'audit',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor',p.nickname,'action',a.action,'target',a.target,'reason',a.reason,'date',a.created_at) order by a.created_at desc),'[]') from (select * from voku_private.audit order by created_at desc limit 100) a join public.community_profiles p on p.id=a.actor_id));
end $$;

create function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member(); staff boolean:=voku_private.is_staff(); pid uuid; cid uuid; target uuid; p public.community_posts; c public.community_comments; r public.community_reports; value boolean; v_reason text:=btrim(coalesce(p_payload->>'reason','')); own_role text; target_role text;
begin
  select role into own_role from voku_private.members where id=uid;
  if p_action='profile' then
    if coalesce(p_payload->>'nickname','') !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
    perform voku_private.throttle(uid,'profile',30);
    update public.community_profiles set nickname=p_payload->>'nickname' where id=uid;
  elsif p_action='post_save' then
    pid:=nullif(p_payload->>'id','')::uuid;
    if pid is null then
      perform voku_private.throttle(uid,'post',30);
      if coalesce((p_payload->>'notice')::boolean,false) and not staff then raise exception '공지 작성은 운영진만 할 수 있습니다.'; end if;
      insert into public.community_posts(author_id,category,title,body,record_id,pinned) values(uid,p_payload->>'category',btrim(p_payload->>'title'),btrim(p_payload->>'body'),nullif(p_payload->>'recordId',''),coalesce((p_payload->>'notice')::boolean,false)) returning id into pid;
    else
      select * into p from public.community_posts where id=pid for update;
      if p.id is null or p.author_id<>uid or p.status<>'published' then raise exception '본인의 공개된 글만 수정할 수 있습니다.'; end if;
      update public.community_posts set category=p_payload->>'category',title=btrim(p_payload->>'title'),body=btrim(p_payload->>'body'),record_id=nullif(p_payload->>'recordId',''),updated_at=now() where id=pid;
    end if;
  elsif p_action in ('suspend','restore_member','set_role') then
    if not staff then raise exception '운영 권한이 필요합니다.'; end if;
    target:=(p_payload->>'userId')::uuid;
    select role into target_role from voku_private.members where id=target for update;
    if target=uid or target_role is null or target_role='admin' or (target_role='moderator' and own_role<>'admin') then raise exception '이 회원에 대한 관리 권한이 없습니다.'; end if;
    if p_action='set_role' then
      if own_role<>'admin' or coalesce(p_payload->>'role','') not in ('member','moderator') then raise exception '관리자만 운영진 권한을 변경할 수 있습니다.'; end if;
      update voku_private.members set role=p_payload->>'role' where id=target;
    elsif p_action='suspend' then
      if char_length(v_reason)<2 or char_length(v_reason)>500 or coalesce((p_payload->>'days')::integer,0) not in (1,7,30,36500) then raise exception '제한 기간과 사유를 입력해 주세요.'; end if;
      update voku_private.members set suspended_until=now()+make_interval(days=>(p_payload->>'days')::integer),suspension_reason=v_reason where id=target;
    else update voku_private.members set suspended_until=null,suspension_reason='' where id=target; end if;
    insert into voku_private.audit(actor_id,action,target,reason) values(uid,p_action,target::text,v_reason);
  elsif p_action='read_notifications' then
    update public.community_notifications set is_read=true where user_id=uid;
  elsif p_action='block' then
    target:=(p_payload->>'userId')::uuid;
    if target=uid or exists(select 1 from voku_private.members where id=target and role<>'member') then raise exception '본인이나 운영진은 차단할 수 없습니다.'; end if;
    if coalesce((p_payload->>'value')::boolean,false) then insert into public.community_blocks values(uid,target) on conflict do nothing; else delete from public.community_blocks where user_id=uid and target_id=target; end if;
  elsif p_action='resolve_report' then
    if not staff then raise exception '운영 권한이 필요합니다.'; end if;
    select * into r from public.community_reports where id=(p_payload->>'id')::uuid for update;
    if r.id is null or r.status<>'open' then raise exception '이미 처리했거나 없는 신고입니다.'; end if;
    if char_length(v_reason)<2 or char_length(v_reason)>500 then raise exception '처리 사유를 입력해 주세요.'; end if;
    if p_payload->>'decision'='hide' then
      if r.comment_id is not null then update public.community_comments set status='hidden' where id=r.comment_id and status='published'; else update public.community_posts set status='hidden' where id=r.post_id and status='published'; end if;
    elsif coalesce(p_payload->>'decision','')<>'dismiss' then raise exception '처리 방식을 선택해 주세요.'; end if;
    update public.community_reports set status=case when p_payload->>'decision'='hide' then 'resolved' else 'dismissed' end,resolution=v_reason,resolved_at=now(),resolved_by=uid where id=r.id;
    insert into voku_private.audit(actor_id,action,target,reason) values(uid,'report_'||(p_payload->>'decision'),r.id::text,v_reason);
  else
    pid:=(p_payload->>'postId')::uuid;
    select * into p from public.community_posts where id=pid for update;
    if p.id is null or p.status='deleted' or (p.status<>'published' and not staff) then raise exception '공개되지 않았거나 없는 글입니다.'; end if;
    if p_action='post_delete' then
      if p.author_id<>uid then raise exception '본인의 글만 삭제할 수 있습니다.'; end if;
      update public.community_posts set status='deleted',updated_at=now() where id=pid;
    elsif p_action in ('post_pin','post_lock','post_visibility') then
      if not staff then raise exception '운영 권한이 필요합니다.'; end if;
      value:=coalesce((p_payload->>'value')::boolean,false);
      if p_action='post_pin' then update public.community_posts set pinned=value where id=pid;
      elsif p_action='post_lock' then update public.community_posts set locked=value where id=pid;
      else
        if char_length(v_reason)<2 or char_length(v_reason)>500 then raise exception '처리 사유를 입력해 주세요.'; end if;
        update public.community_posts set status=case when value then 'hidden' else 'published' end where id=pid;
      end if;
      insert into voku_private.audit(actor_id,action,target,reason) values(uid,p_action,pid::text,coalesce(v_reason,'')||' ['||value||']');
    elsif p_action='comment_save' then
      if p.locked then raise exception '댓글 작성이 잠긴 글입니다.'; end if;
      cid:=nullif(p_payload->>'id','')::uuid;
      if cid is null then
        perform voku_private.throttle(uid,'comment',5);
        target:=nullif(p_payload->>'parentId','')::uuid;
        if target is not null and not exists(select 1 from public.community_comments where id=target and post_id=pid and parent_id is null and status='published') then raise exception '답글을 달 수 없는 댓글입니다.'; end if;
        insert into public.community_comments(post_id,author_id,parent_id,body) values(pid,uid,target,btrim(p_payload->>'body')) returning id into cid;
        insert into public.community_notifications(user_id,post_id,text) select recipient,pid,(select nickname from public.community_profiles where id=uid)||'님이 댓글을 남겼습니다.' from (select p.author_id recipient union select author_id from public.community_comments where id=target) recipients where recipient<>uid;
      else
        select * into c from public.community_comments where id=cid for update;
        if c.author_id<>uid or c.post_id<>pid or c.status<>'published' or c.id is null then raise exception '본인의 댓글만 수정할 수 있습니다.'; end if;
        update public.community_comments set body=btrim(p_payload->>'body'),updated_at=now() where id=cid;
      end if;
    elsif p_action='comment_delete' then
      cid:=(p_payload->>'id')::uuid;
      select * into c from public.community_comments where id=cid for update;
      if c.id is null or c.post_id<>pid or (c.author_id<>uid and not staff) then raise exception '댓글을 삭제할 권한이 없습니다.'; end if;
      if c.author_id<>uid and (char_length(v_reason)<2 or char_length(v_reason)>500) then raise exception '처리 사유를 입력해 주세요.'; end if;
      update public.community_comments set status=case when c.author_id=uid then 'deleted' else 'hidden' end where id=cid;
      if c.author_id<>uid then insert into voku_private.audit(actor_id,action,target,reason) values(uid,'comment_hide',cid::text,v_reason); end if;
    elsif p_action in ('like','bookmark') then
      value:=coalesce((p_payload->>'value')::boolean,false);
      if p_action='like' then
        if p.author_id=uid then raise exception '본인의 글에는 추천할 수 없습니다.'; end if;
        if value then insert into public.community_likes values(uid,pid) on conflict do nothing; else delete from public.community_likes where user_id=uid and post_id=pid; end if;
      else
        if value then insert into public.community_bookmarks(user_id,post_id) values(uid,pid) on conflict do nothing; else delete from public.community_bookmarks where user_id=uid and post_id=pid; end if;
      end if;
    elsif p_action='report' then
      perform voku_private.throttle(uid,'report',10);
      cid:=nullif(p_payload->>'commentId','')::uuid;
      if cid is not null and not exists(select 1 from public.community_comments where id=cid and post_id=pid and status='published') then raise exception '신고할 댓글을 찾을 수 없습니다.'; end if;
      insert into public.community_reports(reporter_id,post_id,comment_id,reason,detail) values(uid,pid,cid,v_reason,coalesce(p_payload->>'detail',''));
    else raise exception '지원하지 않는 요청입니다.';
    end if;
  end if;
  return jsonb_build_object('postId',pid,'commentId',cid);
exception when unique_violation then raise exception '이미 사용 중인 닉네임이거나 이미 접수한 신고입니다.';
end $$;

revoke all on all functions in schema voku_private from public,anon,authenticated;
revoke all on function public.community_feed(text,text,text,integer),public.community_post(uuid),public.community_account(),public.community_admin(text),public.community_action(text,jsonb) from public;
grant execute on function public.community_feed(text,text,text,integer),public.community_post(uuid) to anon,authenticated;
grant execute on function public.community_account(),public.community_admin(text),public.community_action(text,jsonb) to authenticated;
commit;
