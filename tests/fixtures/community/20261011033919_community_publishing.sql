-- Additive publishing support. Existing plain-text posts and clients remain valid.
alter table public.community_posts
  add column body_format text not null default 'plain' check (body_format in ('plain','markdown')),
  add column view_count bigint not null default 0 check (view_count >= 0);

create table public.community_media (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.community_profiles(id),
  post_id uuid references public.community_posts(id),
  path text not null unique,
  position smallint check (position between 0 and 5),
  created_at timestamptz not null default now(),
  check ((post_id is null) = (position is null))
);
create index community_media_owner on public.community_media(author_id,created_at);
create index community_media_post on public.community_media(post_id,position) where post_id is not null;
alter table public.community_media enable row level security;
revoke all on public.community_media from public,anon,authenticated;
grant select on public.community_media to anon,authenticated;
create policy community_media_read on public.community_media for select to anon,authenticated
using (author_id=(select auth.uid()) or exists(select 1 from public.community_posts p where p.id=post_id and p.status='published'));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('community-photos','community-photos',false,2097152,array['image/jpeg']);

-- Storage policies use private helpers so hidden/deleted attachments cannot leak
-- through a public bucket. Signed URLs expire after five minutes.
create function voku_private.media_readable(p_path text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.community_media m left join public.community_posts p on p.id=m.post_id
    where m.path=p_path and (m.author_id=auth.uid() or p.status='published' or (m.post_id is not null and voku_private.is_staff())));
$$;
create function voku_private.media_uploadable(p_path text) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare uid uuid := voku_private.require_member();
begin
  return exists(select 1 from public.community_media where path=p_path and author_id=uid and post_id is null and created_at>now()-interval '24 hours');
end $$;
create function voku_private.media_removable(p_path text) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists(select 1 from public.community_media where path=p_path and author_id=auth.uid() and post_id is null);
$$;
revoke all on function voku_private.media_readable(text),voku_private.media_uploadable(text),voku_private.media_removable(text) from public,anon,authenticated;
grant execute on function voku_private.media_readable(text) to anon,authenticated;
grant execute on function voku_private.media_uploadable(text),voku_private.media_removable(text) to authenticated;
create policy community_photo_read on storage.objects for select to anon,authenticated
  using(bucket_id='community-photos' and voku_private.media_readable(name));
create policy community_photo_insert on storage.objects for insert to authenticated
  with check(bucket_id='community-photos' and voku_private.media_uploadable(name));
create policy community_photo_delete on storage.objects for delete to authenticated
  using(bucket_id='community-photos' and voku_private.media_removable(name));
-- No UPDATE policy: uploaded files are immutable; replacements get new paths.

create function public.community_media_reserve(p_count integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid := voku_private.require_member(); mid uuid; result jsonb := '[]';
begin
  if p_count is null or p_count not between 1 and 6 then raise exception '사진은 한 번에 6장까지 첨부할 수 있습니다.'; end if;
  perform 1 from voku_private.members where id=uid for update;
  if (select count(*) from public.community_media where author_id=uid and post_id is null)+p_count>12 then
    raise exception '미완료 사진 업로드가 많습니다. 잠시 후 다시 시도해 주세요.';
  end if;
  for i in 1..p_count loop
    mid := gen_random_uuid();
    insert into public.community_media(id,author_id,path) values(mid,uid,uid::text||'/'||mid::text||'.jpg');
    result := result || jsonb_build_array(jsonb_build_object('id',mid,'path',uid::text||'/'||mid::text||'.jpg'));
  end loop;
  return result;
end $$;
create function public.community_media_discard(p_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  -- Delete bytes through Storage API first; SQL must not orphan stored objects.
  delete from public.community_media m where m.id=any(p_ids) and m.author_id=uid and m.post_id is null
    and not exists(select 1 from storage.objects o where o.bucket_id='community-photos' and o.name=m.path);
end $$;
revoke all on function public.community_media_reserve(integer),public.community_media_discard(uuid[]) from public,anon;
grant execute on function public.community_media_reserve(integer),public.community_media_discard(uuid[]) to authenticated;

alter function public.community_action(text,jsonb) rename to action_before_media;
alter function public.action_before_media(text,jsonb) set schema voku_private;
revoke all on function voku_private.action_before_media(text,jsonb) from public,anon,authenticated;
create function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; pid uuid; photo_ids uuid[]; uid uuid := auth.uid();
begin
  result := voku_private.action_before_media(p_action,p_payload);
  if p_action='post_save' then
    pid := (result->>'postId')::uuid;
    if p_payload ? 'bodyFormat' then
      if coalesce(p_payload->>'bodyFormat','') not in ('plain','markdown') then raise exception '본문 형식을 확인해 주세요.'; end if;
      update public.community_posts set body_format=p_payload->>'bodyFormat' where id=pid;
    end if;
    if p_payload ? 'photoIds' then
      if jsonb_typeof(p_payload->'photoIds')<>'array' then raise exception '사진 목록을 확인해 주세요.'; end if;
      select coalesce(array_agg(value::uuid),'{}') into photo_ids from jsonb_array_elements_text(p_payload->'photoIds');
      if cardinality(photo_ids)>6 or cardinality(photo_ids)<>(select count(distinct x) from unnest(photo_ids)x) then
        raise exception '중복 없이 사진을 6장까지 첨부해 주세요.';
      end if;
      perform 1 from public.community_media where id=any(photo_ids) order by id for update;
      if cardinality(photo_ids)<>(select count(*) from public.community_media m where m.id=any(photo_ids) and m.author_id=uid
        and (m.post_id is null or m.post_id=pid) and exists(select 1 from storage.objects o
          where o.bucket_id='community-photos' and o.name=m.path and o.metadata->>'mimetype'='image/jpeg'
          and (o.metadata->>'size')::bigint between 1 and 2097152)) then
        raise exception '업로드를 마친 본인의 사진만 첨부할 수 있습니다.';
      end if;
      update public.community_media set post_id=null,position=null where post_id=pid and not(id=any(photo_ids));
      update public.community_media m set post_id=pid,position=s.n-1 from unnest(photo_ids) with ordinality s(id,n) where m.id=s.id;
    end if;
  end if;
  return result;
end $$;
revoke all on function public.community_action(text,jsonb) from public,anon;
grant execute on function public.community_action(text,jsonb) to authenticated;

-- Keep the established post JSON shape and append publishing fields.
create or replace function voku_private.post_json(pid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p.id,'authorId',p.author_id,'author',a.nickname,'authorRole',m.role,'title',p.title,'body',p.body,'category',p.category,'recordId',p.record_id,'date',p.created_at,'updatedAt',p.updated_at,'pinned',p.pinned,'locked',p.locked,'status',p.status,'views',p.view_count,'bodyFormat',p.body_format,
    'photos',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'path',m.path) order by m.position),'[]') from public.community_media m where m.post_id=p.id),
    'likes',(select count(*) from public.community_likes where post_id=p.id),
    'commentCount',(select count(*) from public.community_comments where post_id=p.id and status='published'),
    'liked',exists(select 1 from public.community_likes where post_id=p.id and user_id=auth.uid()),
    'bookmarked',exists(select 1 from public.community_bookmarks where post_id=p.id and user_id=auth.uid()))
  from public.community_posts p join public.community_profiles a on a.id=p.author_id join voku_private.members m on m.id=p.author_id where p.id=pid;
$$;
revoke all on function voku_private.post_json(uuid) from public,anon,authenticated;

create table voku_private.post_viewers (
  post_id uuid not null references public.community_posts(id),
  viewer_key text not null,
  viewed_on date not null,
  primary key(post_id,viewer_key)
);
alter table voku_private.post_viewers enable row level security;
revoke all on voku_private.post_viewers from public,anon,authenticated;
create function public.community_post_view(p_id uuid,p_visitor uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare p public.community_posts; uid uuid := auth.uid(); day date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_visitor is null then raise exception '방문 정보를 확인해 주세요.'; end if;
  select * into p from public.community_posts where id=p_id and status='published' for update;
  if p.id is null then raise exception '글을 찾을 수 없거나 공개되지 않은 글입니다.'; end if;
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
