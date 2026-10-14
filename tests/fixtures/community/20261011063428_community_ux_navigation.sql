-- Categories describe the subject; linked archives are a separate filter.
-- Legacy music rows/clients remain valid and appear under 자유글.
create function voku_private.listing_candidates(p_category text, p_query text, p_linked boolean)
returns setof public.community_posts language sql stable security definer set search_path='' as $$
  select p.* from voku_private.feed_candidates(coalesce(p_query,'')) p
  where (not p.pinned or p_category='공지' or coalesce(p_query,'')<>'')
    and (coalesce(p_category,'') in ('','전체')
      or (p_category='공지' and p.pinned)
      or (p_category in ('자유글','일상','음악') and p.category in ('일상','음악'))
      or (p_category='자료 이야기' and p.record_id is not null and voku_private.post_readable(p.id))
      or (p_category in ('추억','질문','동문소식') and p.category=p_category))
    and (not coalesce(p_linked,false) or (p.record_id is not null and voku_private.post_readable(p.id)));
$$;
revoke all on function voku_private.listing_candidates(text,text,boolean) from public,anon,authenticated;

-- Replace the signature rather than leaving ambiguous RPC overloads. The new
-- optional argument keeps the existing four-argument clients working.
drop function public.community_feed(text,text,text,integer);
create function public.community_feed(p_category text default '',p_sort text default 'latest',p_query text default '',p_page integer default 1,p_linked boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; notices jsonb; total integer; page integer; counts jsonb;
begin
  if p_page<1 or char_length(p_query)>100 then raise exception '검색 조건을 확인해 주세요.'; end if;
  select count(*) into total from voku_private.listing_candidates(p_category,p_query,p_linked);
  page:=least(greatest(coalesce(p_page,1),1),greatest(1,ceil(total/20.0)::integer));
  select coalesce(jsonb_agg(voku_private.post_json(id) order by votes desc,created_at desc,id desc),'[]') into result from (
    select p.id,p.created_at,case when p_sort='popular' and voku_private.post_readable(p.id) then (select count(*) from public.community_likes where post_id=p.id) else 0 end votes
    from voku_private.listing_candidates(p_category,p_query,p_linked) p
    order by votes desc,p.created_at desc,p.id desc limit 20 offset (page-1)*20
  ) s;
  select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc,id desc),'[]') into notices
    from (select id,created_at from public.community_posts where status='published' and pinned and not is_secret order by created_at desc,id desc limit 10)p;
  select jsonb_object_agg(label,n) into counts from (
    select label,(select count(*) from voku_private.listing_candidates(label,p_query,p_linked)) n
    from unnest(array['전체','자유글','추억','질문','동문소식','공지']) label
  ) counts;
  return jsonb_build_object('posts',result,'notices',notices,'total',total,'page',page,'categoryCounts',counts);
end $$;
revoke all on function public.community_feed(text,text,text,integer,boolean) from public,anon,authenticated;
grant execute on function public.community_feed(text,text,text,integer,boolean) to anon,authenticated;

-- A five-row window can cross the main board's twenty-row page boundaries.
-- All content still goes through the existing privacy-aware JSON serializer.
create function public.community_reading(p_id uuid,p_category text default '',p_sort text default 'latest',p_query text default '',p_start integer default null,p_linked boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ordered uuid[]; total integer; first_row integer; anchor integer; result jsonb;
begin
  if char_length(p_query)>100 or p_start<0 then raise exception '목록 조건을 확인해 주세요.'; end if;
  select array_agg(id order by votes desc,created_at desc,id desc) into ordered from (
    select p.id,p.created_at,case when p_sort='popular' and voku_private.post_readable(p.id) then (select count(*) from public.community_likes where post_id=p.id) else 0 end votes
    from voku_private.listing_candidates(p_category,p_query,p_linked) p
  ) rows;
  total:=coalesce(array_length(ordered,1),0);
  anchor:=coalesce(array_position(ordered,p_id)-1,0);
  first_row:=least(greatest(0,coalesce(p_start,anchor-2)),greatest(0,total-5));
  select coalesce(jsonb_agg(voku_private.post_json(id) order by position),'[]') into result
    from unnest(ordered) with ordinality rows(id,position) where position>first_row and position<=first_row+5;
  return jsonb_build_object('posts',result,'total',total,'start',first_row);
end $$;
revoke all on function public.community_reading(uuid,text,text,text,integer,boolean) from public,anon,authenticated;
grant execute on function public.community_reading(uuid,text,text,text,integer,boolean) to anon,authenticated;
