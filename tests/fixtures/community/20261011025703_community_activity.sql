-- Additive APIs: existing clients and their account summaries remain compatible.
create function public.community_activity(p_kind text, p_page integer default 1)
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
      where c.author_id=uid and c.status='published' and p.status='published';
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
        where c.author_id=uid and c.status='published' and p.status='published'
        order by c.created_at desc,c.id desc limit 20 offset (page-1)*20
      ) c;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'postId',post_id,'text',text,'date',created_at,'read',is_read
    ) order by created_at desc,id desc),'[]') into items from (
      select * from public.community_notifications where user_id=uid
      order by created_at desc,id desc limit 20 offset (page-1)*20
    ) n;
  end if;
  return jsonb_build_object('kind',p_kind,'items',items,'total',total,'page',page,'pageSize',20);
end $$;

-- A missing ID explicitly means "mark all". An ID can only update its owner’s row.
create function public.community_read_notifications(p_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  update public.community_notifications set is_read=true
    where user_id=uid and not is_read and (p_id is null or id=p_id);
  return '{}'::jsonb;
end $$;

create or replace function public.community_account() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception '로그인이 필요합니다.'; end if;
  return jsonb_build_object('profile',voku_private.profile_json(uid),
  'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]') from (select id,created_at from public.community_posts where author_id=uid and status='published' order by created_at desc,id desc limit 100) p),
  'comments',(select coalesce(jsonb_agg(voku_private.comment_json(id) order by created_at desc,id desc),'[]') from (select c.id,c.created_at from public.community_comments c join public.community_posts p on p.id=c.post_id where c.author_id=uid and c.status='published' and p.status='published' order by c.created_at desc,c.id desc limit 100) c),
  'saved',(select coalesce(jsonb_agg(voku_private.post_json(p.id) order by b.created_at desc),'[]') from public.community_bookmarks b join public.community_posts p on p.id=b.post_id where b.user_id=uid and p.status='published'),
  'notifications',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'postId',post_id,'text',text,'date',created_at,'read',is_read) order by created_at desc,id desc),'[]') from (select * from public.community_notifications where user_id=uid order by created_at desc,id desc limit 50) n),
  'unreadNotificationCount',(select count(*) from public.community_notifications where user_id=uid and not is_read),
  'blocked',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname)),'[]') from public.community_blocks b join public.community_profiles p on p.id=b.target_id where b.user_id=uid),
  'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'postId',r.post_id,'commentId',r.comment_id,'title',p.title,'body','','reporter','','reason',r.reason,'detail',r.detail,'status',r.status,'date',r.created_at,'resolution',r.resolution,'targetAuthorId',p.author_id) order by r.created_at desc),'[]') from public.community_reports r join public.community_posts p on p.id=r.post_id where r.reporter_id=uid));
end $$;

revoke all on function public.community_activity(text,integer),
  public.community_read_notifications(uuid),public.community_account() from public,anon;
grant execute on function public.community_activity(text,integer),
  public.community_read_notifications(uuid),public.community_account() to authenticated;
