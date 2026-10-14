-- Account-only archive bookmarks and a paginated board-admin API.
-- Keep the existing community_action/community_admin and operations APIs intact.
begin;
create table voku_private.archive_bookmarks (
  user_id uuid not null references public.community_profiles(id) on delete cascade,
  record_id text not null check (record_id ~ '^voku_[a-z0-9_]+$' and char_length(record_id)<=200),
  created_at timestamptz not null default now(),
  primary key(user_id,record_id)
);
alter table voku_private.archive_bookmarks enable row level security;
revoke all on voku_private.archive_bookmarks from public,anon,authenticated;

alter function public.community_account() rename to account_before_archive_saved;
alter function public.account_before_archive_saved() set schema voku_private;
revoke all on function voku_private.account_before_archive_saved() from public,anon,authenticated;
create function voku_private.account_with_archive() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  result:=voku_private.account_before_archive_saved();
  return result || jsonb_build_object('archiveSaved',(select coalesce(jsonb_agg(record_id order by created_at desc,record_id),'[]')
    from voku_private.archive_bookmarks where user_id=(select auth.uid())));
end $$;
create function public.community_account() returns jsonb language sql stable security invoker set search_path='' as $$
  select voku_private.account_with_archive();
$$;

create function voku_private.archive_bookmark(p_ids text[],p_saved boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member();
begin
  if p_ids is null or cardinality(p_ids) not between 1 and 6000 or p_saved is null
    or exists(select 1 from unnest(p_ids) id where id is null or id !~ '^voku_[a-z0-9_]+$' or char_length(id)>200)
  then raise exception '저장할 큐시트를 확인해 주세요.'; end if;
  if p_saved then
    insert into voku_private.archive_bookmarks(user_id,record_id) select uid,id from unnest(p_ids) id on conflict do nothing;
  else
    delete from voku_private.archive_bookmarks where user_id=uid and record_id=any(p_ids);
  end if;
  return '{}'::jsonb;
end $$;
create function public.community_archive_bookmark(p_ids text[],p_saved boolean) returns jsonb
language sql security invoker set search_path='' as $$ select voku_private.archive_bookmark(p_ids,p_saved); $$;

create function voku_private.restore_comment(p_id uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member(); c public.community_comments;
begin
  if not voku_private.is_staff() then raise exception '게시판 관리 권한이 필요합니다.'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 2 and 500 then raise exception '처리 사유를 입력해 주세요.'; end if;
  select * into c from public.community_comments where id=p_id for update;
  if c.id is null or c.status<>'hidden' or not voku_private.post_readable(c.post_id) then
    raise exception '숨긴 댓글만 다시 공개할 수 있습니다. 최신 상태를 확인해 주세요.';
  end if;
  update public.community_comments set status='published',updated_at=now() where id=p_id;
  insert into voku_private.audit(actor_id,action,target,reason) values(uid,'comment_restore',p_id::text,btrim(p_reason));
  return jsonb_build_object('postId',c.post_id,'commentId',c.id);
end $$;
create function public.community_restore_comment(p_id uuid,p_reason text) returns jsonb
language sql security invoker set search_path='' as $$ select voku_private.restore_comment(p_id,p_reason); $$;

create index community_hidden_comments_order on public.community_comments(created_at desc,id desc) where status='hidden';

create function voku_private.board_admin(p_tab text,p_filter text,p_query text,p_page integer) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member(); total integer; page integer; rows jsonb; pending integer;
begin
  if not voku_private.is_staff() then raise exception '게시판 관리 권한이 필요합니다.'; end if;
  if p_tab is null or p_tab not in ('posts','comments','reports','audit') or p_query is null or char_length(p_query)>100
    or p_page is null or p_page<1 or p_filter is null
    or (p_tab='posts' and p_filter not in ('all','notice','hidden'))
    or (p_tab='reports' and p_filter not in ('all','open','done'))
  then raise exception '검색 조건을 확인해 주세요.'; end if;
  select count(*) into pending from public.community_reports where status='open';
  if p_tab='posts' then
    select count(*) into total from public.community_posts p where p.status<>'deleted' and strpos(lower(p.title),lower(p_query))>0
      and (p_filter='all' or (p_filter='notice' and p.pinned) or (p_filter='hidden' and p.status='hidden'));
    page:=least(p_page,greatest(1,ceil(total/20.0)::integer));
    select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]') into rows from (
      select id,created_at from public.community_posts p where p.status<>'deleted' and strpos(lower(p.title),lower(p_query))>0
        and (p_filter='all' or (p_filter='notice' and p.pinned) or (p_filter='hidden' and p.status='hidden'))
      order by created_at desc,id desc limit 20 offset (page-1)*20) x;
  elsif p_tab='comments' then
    select count(*) into total from public.community_comments c join public.community_posts p on p.id=c.post_id
      where c.status='hidden' and p.status<>'deleted';
    page:=least(p_page,greatest(1,ceil(total/20.0)::integer));
    select coalesce(jsonb_agg(voku_private.comment_json(id) || jsonb_build_object('body',body,'postTitle',title) order by created_at desc,id desc),'[]') into rows from (
      select c.id,c.body,c.created_at,p.title from public.community_comments c join public.community_posts p on p.id=c.post_id
      where c.status='hidden' and p.status<>'deleted' order by c.created_at desc,c.id desc limit 20 offset (page-1)*20) x;
  elsif p_tab='reports' then
    select count(*) into total from public.community_reports where p_filter='all' or (p_filter='open' and status='open') or (p_filter='done' and status<>'open');
    page:=least(p_page,greatest(1,ceil(total/20.0)::integer));
    select coalesce(jsonb_agg(voku_private.report_json(id) order by (status='open') desc,created_at desc,id desc),'[]') into rows from (
      select id,status,created_at from public.community_reports where p_filter='all' or (p_filter='open' and status='open') or (p_filter='done' and status<>'open')
      order by (status='open') desc,created_at desc,id desc limit 20 offset (page-1)*20) x;
  else
    select count(*) into total from voku_private.audit where action in ('post_pin','post_lock','post_visibility','comment_hide','comment_restore','report_hide','report_dismiss');
    page:=least(p_page,greatest(1,ceil(total/20.0)::integer));
    select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor',actor.nickname,'action',a.action,'target',a.target,'reason',a.reason,'date',a.created_at,
      'postId',case when p.status<>'deleted' then p.id end,'postTitle',case when p.status<>'deleted' then p.title else '삭제된 글' end,
      'commentId',c.id,'excerpt',case when c.status='deleted' then '작성자가 삭제한 댓글입니다.' else left(c.body,180) end) order by a.created_at desc,a.id desc),'[]') into rows
    from (select * from voku_private.audit where action in ('post_pin','post_lock','post_visibility','comment_hide','comment_restore','report_hide','report_dismiss')
      order by created_at desc,id desc limit 20 offset (page-1)*20) a
    join public.community_profiles actor on actor.id=a.actor_id
    left join public.community_reports r on a.action in ('report_hide','report_dismiss') and r.id::text=a.target
    left join public.community_comments c on (a.action in ('comment_hide','comment_restore') and c.id::text=a.target) or (r.comment_id=c.id)
    left join public.community_posts p on (a.action in ('post_pin','post_lock','post_visibility') and p.id::text=a.target) or p.id=coalesce(c.post_id,r.post_id);
  end if;
  return jsonb_build_object('total',total,'page',page,'pageSize',20,'pendingReports',pending,
    'posts',case when p_tab='posts' then rows else '[]'::jsonb end,
    'comments',case when p_tab='comments' then rows else '[]'::jsonb end,
    'reports',case when p_tab='reports' then rows else '[]'::jsonb end,
    'audit',case when p_tab='audit' then rows else '[]'::jsonb end);
end $$;
create function public.community_board_admin(p_tab text default 'posts',p_filter text default 'all',p_query text default '',p_page integer default 1) returns jsonb
language sql stable security invoker set search_path='' as $$ select voku_private.board_admin(p_tab,p_filter,p_query,p_page); $$;

-- Private tables have no direct client grants. Each callable implementation derives
-- its identity from auth.uid(); none accepts a target user's identity.
grant usage on schema voku_private to authenticated;
revoke all on function voku_private.account_with_archive(),voku_private.archive_bookmark(text[],boolean),voku_private.restore_comment(uuid,text),voku_private.board_admin(text,text,text,integer) from public,anon,authenticated;
revoke all on function public.community_account(),public.community_archive_bookmark(text[],boolean),public.community_restore_comment(uuid,text),public.community_board_admin(text,text,text,integer) from public,anon,authenticated;
grant execute on function voku_private.account_with_archive(),voku_private.archive_bookmark(text[],boolean),voku_private.restore_comment(uuid,text),voku_private.board_admin(text,text,text,integer) to authenticated;
grant execute on function public.community_account(),public.community_archive_bookmark(text[],boolean),public.community_restore_comment(uuid,text),public.community_board_admin(text,text,text,integer) to authenticated;
commit;
