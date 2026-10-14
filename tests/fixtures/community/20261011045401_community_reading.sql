-- Community reading: private posts, comment reactions and safe list summaries.
-- Existing membership/roles and publishing APIs remain in use.
alter table public.community_posts
  add column is_secret boolean not null default false,
  add column sample_batch text,
  add constraint community_secret_not_pinned check (not (is_secret and pinned));
alter table public.community_comments add column is_sample boolean not null default false;
alter table public.community_notifications add column comment_id uuid references public.community_comments(id) on delete set null;
create index community_notifications_comment on public.community_notifications(comment_id) where comment_id is not null;
create index community_posts_sample_batch on public.community_posts(sample_batch) where sample_batch is not null;

create function voku_private.post_readable(pid uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.community_posts p where p.id=pid and p.status<>'deleted'
    and (p.status='published' or voku_private.is_staff())
    and (not p.is_secret or p.author_id=(select auth.uid()) or voku_private.is_staff()));
$$;
revoke all on function voku_private.post_readable(uuid) from public,anon,authenticated;
grant execute on function voku_private.post_readable(uuid) to anon,authenticated;
drop policy posts_public on public.community_posts;
create policy posts_public on public.community_posts for select to anon,authenticated using(voku_private.post_readable(id));
drop policy comments_public on public.community_comments;
create policy comments_public on public.community_comments for select to anon,authenticated using(status='published' and voku_private.post_readable(post_id));
drop policy community_media_read on public.community_media;
create policy community_media_read on public.community_media for select to anon,authenticated using(author_id=(select auth.uid()) or voku_private.post_readable(post_id));
create or replace function voku_private.media_readable(p_path text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.community_media m where m.path=p_path and
    (m.author_id=(select auth.uid()) or voku_private.post_readable(m.post_id)));
$$;

create table public.community_comment_likes (
  user_id uuid not null references public.community_profiles(id),
  comment_id uuid not null references public.community_comments(id),
  primary key(user_id,comment_id)
);
create index community_comment_likes_comment on public.community_comment_likes(comment_id);
alter table public.community_comment_likes enable row level security;
revoke all on public.community_comment_likes from public,anon,authenticated;
grant select on public.community_comment_likes to authenticated;
create policy comment_likes_own on public.community_comment_likes for select to authenticated using(user_id=(select auth.uid()));

alter function voku_private.post_json(uuid) rename to post_json_before_privacy;
create function voku_private.post_json(pid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select case when voku_private.post_readable(pid) then voku_private.post_json_before_privacy(pid)
    else jsonb_build_object('id',p.id,'authorId',p.author_id,'author',a.nickname,'authorRole',m.role,
      'title','비밀글입니다','body','','category',p.category,'recordId',null,'date',p.created_at,'updatedAt',p.created_at,
      'pinned',false,'locked',true,'status',p.status,'views',0,'likes',0,'commentCount',0,'liked',false,'bookmarked',false,'photos','[]'::jsonb)
    end || jsonb_build_object('isSecret',p.is_secret,'readable',voku_private.post_readable(pid),'demo',p.sample_batch is not null)
      || case when p.sample_batch is not null then jsonb_build_object('author','VOKU 예시','authorRole','member') else '{}'::jsonb end
  from public.community_posts p join public.community_profiles a on a.id=p.author_id join voku_private.members m on m.id=p.author_id where p.id=pid;
$$;
alter function voku_private.comment_json(uuid) rename to comment_json_before_reactions;
create function voku_private.comment_json(cid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select case when voku_private.post_readable(c.post_id) then
    voku_private.comment_json_before_reactions(cid) || jsonb_build_object(
      'likes',case when c.status='published' then (select count(*) from public.community_comment_likes where comment_id=cid) else 0 end,
      'liked',c.status='published' and exists(select 1 from public.community_comment_likes where comment_id=cid and user_id=(select auth.uid())),
      'demo',c.is_sample) || case when c.is_sample then jsonb_build_object('author','예시 대화','authorRole','member') else '{}'::jsonb end
    else jsonb_build_object('id',c.id,'postId',c.post_id,'authorId',c.author_id,'author','','authorRole','member','date',c.created_at,
      'status','hidden','body','비밀글의 댓글입니다.','likes',0,'liked',false) end
  from public.community_comments c where c.id=cid;
$$;
revoke all on function voku_private.post_json(uuid),voku_private.post_json_before_privacy(uuid),voku_private.comment_json(uuid),voku_private.comment_json_before_reactions(uuid) from public,anon,authenticated;

create or replace function public.community_post(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare p public.community_posts; thread jsonb := '[]';
begin
  select * into p from public.community_posts where id=p_id;
  if p.id is null or p.status='deleted' or (p.status<>'published' and not voku_private.is_staff()) then raise exception '글을 찾을 수 없거나 공개되지 않은 글입니다.'; end if;
  if voku_private.post_readable(p_id) then
    select coalesce(jsonb_agg(voku_private.comment_json(c.id) order by c.created_at,c.id),'[]') into thread
      from public.community_comments c where c.post_id=p_id and not exists(select 1 from public.community_blocks b where b.user_id=auth.uid() and b.target_id=c.author_id);
  end if;
  return jsonb_build_object('post',voku_private.post_json(p_id),'comments',thread);
end $$;

-- Feed search evaluates only content that this caller may actually read.
create function voku_private.feed_candidates(p_query text) returns setof public.community_posts
language sql stable security definer set search_path='' as $$
  select p.* from public.community_posts p where p.status='published'
    and (p.pinned or not exists(select 1 from public.community_blocks b where b.user_id=(select auth.uid()) and b.target_id=p.author_id))
    and (p_query='' or (voku_private.post_readable(p.id) and strpos(lower(p.title||' '||p.body||' '||
      (select nickname from public.community_profiles where id=p.author_id)),lower(p_query))>0));
$$;
revoke all on function voku_private.feed_candidates(text) from public,anon,authenticated;
create or replace function public.community_feed(p_category text default '',p_sort text default 'latest',p_query text default '',p_page integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; notices jsonb; total integer; page integer; counts jsonb;
begin
  if p_page<1 or char_length(p_query)>100 then raise exception '검색 조건을 확인해 주세요.'; end if;
  select count(*) into total from voku_private.feed_candidates(p_query) p
    where (not p.pinned or p_category='공지' or p_query<>'')
      and (p_category in ('','전체') or (p_category='공지' and p.pinned) or (p_category='자료 이야기' and p.record_id is not null and voku_private.post_readable(p.id))
        or (p_category='자유글' and p.category='일상' and p.record_id is null) or p.category=p_category);
  page:=least(greatest(coalesce(p_page,1),1),greatest(1,ceil(total/20.0)::integer));
  select coalesce(jsonb_agg(voku_private.post_json(id) order by votes desc,created_at desc,id desc),'[]') into result from (
    select p.id,p.created_at,case when p_sort='popular' and voku_private.post_readable(p.id) then (select count(*) from public.community_likes where post_id=p.id) else 0 end votes
    from voku_private.feed_candidates(p_query) p
    where (not p.pinned or p_category='공지' or p_query<>'')
      and (p_category in ('','전체') or (p_category='공지' and p.pinned) or (p_category='자료 이야기' and p.record_id is not null and voku_private.post_readable(p.id))
        or (p_category='자유글' and p.category='일상' and p.record_id is null) or p.category=p_category)
    order by votes desc,p.created_at desc,p.id desc limit 20 offset (page-1)*20
  ) s;
  select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]') into notices
    from (select id,created_at from public.community_posts where status='published' and pinned and not is_secret order by created_at desc,id desc limit 3)p;
  select jsonb_object_agg(label,n) into counts from (
    select label,(select count(*) from voku_private.feed_candidates(p_query)p where
      (not p.pinned or label='공지' or p_query<>'') and (label='전체' or (label='공지' and p.pinned)
       or (label='자료 이야기' and p.record_id is not null and voku_private.post_readable(p.id))
       or (label='자유글' and p.category='일상' and p.record_id is null) or p.category=label)) n
    from unnest(array['전체','자료 이야기','자유글','추억','음악','질문','동문소식','공지']) label
  ) counts;
  return jsonb_build_object('posts',result,'notices',notices,'total',total,'page',page,'categoryCounts',counts);
end $$;

alter function public.community_action(text,jsonb) rename to action_before_reading;
alter function public.action_before_reading(text,jsonb) set schema voku_private;
revoke all on function voku_private.action_before_reading(text,jsonb) from public,anon,authenticated;
create function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; pid uuid; cid uuid; uid uuid; parent uuid; p public.community_posts; c public.community_comments;
begin
  if p_payload ? 'postId' then
    pid:=nullif(p_payload->>'postId','')::uuid;
    if not voku_private.post_readable(pid) then raise exception '글을 읽을 권한이 없습니다.'; end if;
  end if;
  if p_action in ('comment_like','comment_save') then
    uid:=voku_private.require_member();
    select * into p from public.community_posts where id=pid for update;
    if p.id is null then raise exception '글을 찾을 수 없습니다.'; end if;
    cid:=nullif(p_payload->>'id','')::uuid;
    if p_action='comment_like' then
      select * into c from public.community_comments where id=cid and post_id=pid and status='published' for update;
      if c.id is null then raise exception '댓글을 찾을 수 없습니다.'; end if;
      if c.author_id=uid then raise exception '본인의 댓글에는 공감할 수 없습니다.'; end if;
      if coalesce((p_payload->>'value')::boolean,false) then
        insert into public.community_comment_likes values(uid,cid) on conflict do nothing;
      else delete from public.community_comment_likes where user_id=uid and comment_id=cid; end if;
    else
      if p.locked then raise exception '댓글 작성이 잠긴 글입니다.'; end if;
      if cid is null then
        perform voku_private.throttle(uid,'comment',5);
        parent:=nullif(p_payload->>'parentId','')::uuid;
        if parent is not null and not exists(select 1 from public.community_comments where id=parent and post_id=pid and parent_id is null and status='published') then raise exception '답글을 달 수 없는 댓글입니다.'; end if;
        insert into public.community_comments(post_id,author_id,parent_id,body) values(pid,uid,parent,btrim(p_payload->>'body')) returning id into cid;
        insert into public.community_notifications(user_id,post_id,comment_id,text)
          select recipient,pid,cid,(select nickname from public.community_profiles where id=uid)||'님이 댓글을 남겼습니다.'
          from (select p.author_id recipient union select author_id from public.community_comments where id=parent) recipients
          where recipient<>uid and (not p.is_secret or recipient=p.author_id or exists(select 1 from voku_private.members where id=recipient and role in ('moderator','admin') and (suspended_until is null or suspended_until<=now())));
      else
        select * into c from public.community_comments where id=cid for update;
        if c.id is null or c.author_id<>uid or c.post_id<>pid or c.status<>'published' then raise exception '본인의 댓글만 수정할 수 있습니다.'; end if;
        update public.community_comments set body=btrim(p_payload->>'body'),updated_at=now() where id=cid;
      end if;
    end if;
    return jsonb_build_object('postId',pid,'commentId',cid);
  end if;
  if p_action='post_save' and nullif(p_payload->>'expectedUpdatedAt','') is not null then
    select * into p from public.community_posts where id=nullif(p_payload->>'id','')::uuid for update;
    if p.updated_at is distinct from (p_payload->>'expectedUpdatedAt')::timestamptz then raise exception '다른 곳에서 글이 수정됐어요. 최신 글을 확인해 주세요.'; end if;
  end if;
  if p_action='post_save' and p_payload ? 'isSecret' then
    if jsonb_typeof(p_payload->'isSecret')<>'boolean' then raise exception '공개 범위를 확인해 주세요.'; end if;
    pid:=nullif(p_payload->>'id','')::uuid;
    if pid is not null then
      select * into p from public.community_posts where id=pid for update;
      if p.is_secret is distinct from (p_payload->>'isSecret')::boolean then raise exception '등록 후 공개 범위는 바꿀 수 없습니다. 새 글로 작성해 주세요.'; end if;
    elsif (p_payload->>'isSecret')::boolean and coalesce((p_payload->>'notice')::boolean,false) then raise exception '공지는 비밀글로 등록할 수 없습니다.'; end if;
  end if;
  if p_action='post_pin' and coalesce((p_payload->>'value')::boolean,false) and exists(select 1 from public.community_posts where id=pid and is_secret) then raise exception '비밀글은 공지로 고정할 수 없습니다.'; end if;
  result:=voku_private.action_before_reading(p_action,p_payload);
  if p_action='post_save' and nullif(p_payload->>'id','') is null then
    update public.community_posts set is_secret=coalesce((p_payload->>'isSecret')::boolean,false) where id=(result->>'postId')::uuid;
  end if;
  return result;
end $$;
revoke all on function public.community_action(text,jsonb) from public,anon;
grant execute on function public.community_action(text,jsonb) to authenticated;

create or replace function public.community_post_view(p_id uuid,p_visitor uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare p public.community_posts; uid uuid := auth.uid(); day date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_visitor is null then raise exception '방문 정보를 확인해 주세요.'; end if;
  select * into p from public.community_posts where id=p_id and status='published' for update;
  if p.id is null or not voku_private.post_readable(p_id) then raise exception '글을 찾을 수 없거나 공개되지 않은 글입니다.'; end if;
  if p.author_id=uid then return p.view_count; end if;
  insert into voku_private.post_viewers(post_id,viewer_key,viewed_on)
    values(p_id,md5(p_id::text||':'||coalesce(uid::text,p_visitor::text)),day)
    on conflict(post_id,viewer_key) do update set viewed_on=excluded.viewed_on where voku_private.post_viewers.viewed_on<excluded.viewed_on;
  if found then
    update public.community_posts set view_count=view_count+1 where id=p_id returning view_count into p.view_count;
  end if;
  return p.view_count;
end $$;
revoke all on function public.community_post_view(uuid,uuid) from public;
grant execute on function public.community_post_view(uuid,uuid) to anon,authenticated;

-- Additive APIs: existing clients and their account summaries remain compatible.
create or replace function public.community_activity(p_kind text, p_page integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  uid uuid := auth.uid();
  total integer;
  page integer;
  items jsonb;
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  if p_kind = 'posts' then
    select count(*) into total from public.community_posts
      where author_id=uid and status='published';
  elsif p_kind = 'comments' then
    select count(*) into total from public.community_comments c
      join public.community_posts p on p.id=c.post_id
      where c.author_id=uid and c.status='published' and p.status='published' and voku_private.post_readable(p.id);
  elsif p_kind = 'notifications' then
    select count(*) into total from public.community_notifications where user_id=uid;
  else
    raise exception '활동 분류를 확인해 주세요.';
  end if;
  page := least(greatest(coalesce(p_page,1),1), greatest(1,ceil(total/20.0)::integer));
  if p_kind = 'posts' then
    select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]')
      into items from (
        select id,created_at from public.community_posts
        where author_id=uid and status='published'
        order by created_at desc,id desc limit 20 offset (page-1)*20
      ) p;
  elsif p_kind = 'comments' then
    select coalesce(jsonb_agg(voku_private.comment_json(id) order by created_at desc,id desc),'[]')
      into items from (
        select c.id,c.created_at from public.community_comments c
        join public.community_posts p on p.id=c.post_id
        where c.author_id=uid and c.status='published' and p.status='published' and voku_private.post_readable(p.id)
        order by c.created_at desc,c.id desc limit 20 offset (page-1)*20
      ) c;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'postId',post_id,'commentId',comment_id,'text',text,'date',created_at,'read',is_read
    ) order by created_at desc,id desc),'[]') into items from (
      select * from public.community_notifications where user_id=uid
      order by created_at desc,id desc limit 20 offset (page-1)*20
    ) n;
  end if;
  return jsonb_build_object('kind',p_kind,'items',items,'total',total,'page',page,'pageSize',20);
end $$;


create or replace function public.community_account() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  return jsonb_build_object('profile',voku_private.profile_json(uid),
  'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]') from (select id,created_at from public.community_posts where author_id=uid and status='published' order by created_at desc,id desc limit 100) p),
  'comments',(select coalesce(jsonb_agg(voku_private.comment_json(id) order by created_at desc,id desc),'[]') from (select c.id,c.created_at from public.community_comments c join public.community_posts p on p.id=c.post_id where c.author_id=uid and c.status='published' and p.status='published' and voku_private.post_readable(p.id) order by c.created_at desc,c.id desc limit 100) c),
  'saved',(select coalesce(jsonb_agg(voku_private.post_json(p.id) order by b.created_at desc),'[]') from public.community_bookmarks b join public.community_posts p on p.id=b.post_id where b.user_id=uid and p.status='published' and voku_private.post_readable(p.id)),
  'notifications',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'postId',post_id,'commentId',comment_id,'text',text,'date',created_at,'read',is_read) order by created_at desc,id desc),'[]') from (select * from public.community_notifications where user_id=uid order by created_at desc,id desc limit 50) n),
  'unreadNotificationCount',(select count(*) from public.community_notifications where user_id=uid and not is_read),
  'blocked',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname)),'[]') from public.community_blocks b join public.community_profiles p on p.id=b.target_id where b.user_id=uid),
  'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'postId',r.post_id,'commentId',r.comment_id,'title',case when voku_private.post_readable(p.id) then p.title else '비밀글입니다' end,'body','','reporter','','reason',r.reason,'detail',r.detail,'status',r.status,'date',r.created_at,'resolution',r.resolution,'targetAuthorId',p.author_id) order by r.created_at desc),'[]') from public.community_reports r join public.community_posts p on p.id=r.post_id where r.reporter_id=uid));
end $$;
