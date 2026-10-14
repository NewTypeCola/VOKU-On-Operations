begin;
create table voku_private.home_banners (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 80),
  image_path text not null unique check (image_path ~ '^[a-f0-9-]{36}/[a-f0-9-]{36}\.jpg$'),
  link text not null default '' check (char_length(link)<=1000),
  width integer not null check (width between 1 and 1600),
  height integer not null check (height between 1 and 1600),
  enabled boolean not null default false,
  position integer not null,
  version integer not null default 1,
  updated_by uuid not null references public.community_profiles(id),
  updated_at timestamptz not null default now()
);
alter table voku_private.home_banners enable row level security;
revoke all on voku_private.home_banners from public,anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('home-banners','home-banners',false,1048576,array['image/jpeg']);

create function voku_private.is_banner_admin() returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from voku_private.members where id=auth.uid() and role='admin'
    and profile_complete and (suspended_until is null or suspended_until<=now()));
$$;
create function voku_private.home_banner_list(manage boolean) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if manage and not voku_private.is_banner_admin() then raise exception '홈 배너는 관리자만 관리할 수 있습니다.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'imagePath',image_path,
    'link',link,'width',width,'height',height,'enabled',enabled,'position',position,'version',version) order by position,id),'[]')
    from voku_private.home_banners where enabled or manage);
end $$;
create function voku_private.home_banner_readable(object_name text) returns boolean
language sql stable security definer set search_path='' as $$
  select voku_private.is_banner_admin() or exists(select 1 from voku_private.home_banners where image_path=object_name and enabled);
$$;
create function voku_private.home_banner_uploadable(object_name text) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member();
begin
  if not voku_private.is_banner_admin() then return false; end if;
  perform pg_advisory_xact_lock(20261014,1);
  if (select count(*) from storage.objects where bucket_id='home-banners')>=64 then
    raise exception '배너 이미지 보관 한도에 도달했습니다. 사용하지 않는 이미지를 정리한 후 다시 시도해 주세요.';
  end if;
  return object_name ~ ('^'||uid::text||'/[a-f0-9-]{36}\.jpg$');
end $$;
create function voku_private.home_banner_removable(object_name text) returns boolean
language plpgsql volatile security definer set search_path='' as $$
begin
  if not voku_private.is_banner_admin() then return false; end if;
  perform pg_advisory_xact_lock(20261014,1);
  return not exists(select 1 from voku_private.home_banners where image_path=object_name);
end $$;
create policy home_banner_read on storage.objects for select to anon,authenticated
  using (bucket_id='home-banners' and voku_private.home_banner_readable(name));
create policy home_banner_upload on storage.objects for insert to authenticated
  with check (bucket_id='home-banners' and voku_private.home_banner_uploadable(name));
create policy home_banner_remove on storage.objects for delete to authenticated
  using (bucket_id='home-banners' and voku_private.home_banner_removable(name));
-- Immutable image paths: replacing a banner never overwrites a cached image.

create function voku_private.home_banner_action(action text,payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member(); b voku_private.home_banners;
  bid uuid; v_title text; v_image_path text; v_link text; total integer;
begin
  if not voku_private.is_banner_admin() then raise exception '홈 배너는 관리자만 관리할 수 있습니다.'; end if;
  perform pg_advisory_xact_lock(20261014,1);
  select count(*) into total from voku_private.home_banners;
  if action='reorder' then
    if jsonb_typeof(payload->'order') is distinct from 'array' then raise exception '배너 순서를 다시 확인해 주세요.'; end if;
    if jsonb_array_length(payload->'order')<>total or
      (select count(distinct e->>'id') from jsonb_array_elements(payload->'order')e)<>total or
      exists(select 1 from jsonb_array_elements(payload->'order')e left join voku_private.home_banners h
        on h.id::text=e->>'id' and h.version::text=e->>'version' where h.id is null) then
      raise exception '다른 화면에서 배너가 변경되었습니다. 새로 불러온 뒤 다시 시도해 주세요.';
    end if;
    update voku_private.home_banners h set position=e.n::integer,version=h.version+1,updated_by=uid,updated_at=now()
      from jsonb_array_elements(payload->'order') with ordinality e(value,n) where h.id::text=e.value->>'id';
    insert into voku_private.audit(actor_id,action,target,reason) values(uid,'home_banner_reorder','home','홈 배너 순서 변경');
    return voku_private.home_banner_list(true);
  end if;
  if action not in ('save','remove') then raise exception '지원하지 않는 배너 작업입니다.'; end if;
  bid:=nullif(payload->>'id','')::uuid;
  if bid is not null then
    select * into b from voku_private.home_banners where id=bid for update;
    if not found or b.version::text is distinct from payload->>'version' then
      raise exception '다른 화면에서 배너가 변경되었습니다. 새로 불러온 뒤 다시 시도해 주세요.';
    end if;
  end if;
  if action='remove' then
    if bid is null then raise exception '삭제할 배너를 선택해 주세요.'; end if;
    delete from voku_private.home_banners where id=bid;
  else
    if bid is null and total>=10 then raise exception '배너는 최대 10개까지 등록할 수 있습니다.'; end if;
    v_title:=btrim(coalesce(payload->>'title',''));
    v_image_path:=payload->>'imagePath';
    v_link:=btrim(coalesce(payload->>'link',''));
    if char_length(v_title) not between 1 and 80 then raise exception '배너 제목은 1~80자로 입력해 주세요.'; end if;
    if char_length(v_link)>1000 or (v_link<>'' and (
      v_link ~ '[[:space:][:cntrl:]]' or strpos(v_link,chr(92))>0 or
      not (v_link ~ '^/(home|archive|board|write|post/[A-Za-z0-9_-]+|read/[^/?#]+)(\?|$)' or
        v_link ~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?([/?#]|$)')
    )) then raise exception '연결 주소는 VOKU On 화면 주소나 https:// 주소를 입력해 주세요.'; end if;
    if v_image_path is null or not exists(select 1 from storage.objects where bucket_id='home-banners' and name=v_image_path
      and metadata->>'mimetype'='image/jpeg' and (metadata->>'size')::bigint between 1 and 1048576) then
      raise exception '배너 이미지를 다시 선택해 주세요.';
    end if;
    if bid is null then
      insert into voku_private.home_banners(title,image_path,link,width,height,enabled,position,updated_by)
      values(v_title,v_image_path,v_link,(payload->>'width')::integer,(payload->>'height')::integer,
        coalesce((payload->>'enabled')::boolean,false),(select coalesce(max(position),0)+1 from voku_private.home_banners),uid) returning id into bid;
    else
      update voku_private.home_banners h set title=v_title,image_path=v_image_path,
        link=v_link,width=(payload->>'width')::integer,height=(payload->>'height')::integer,
        enabled=coalesce((payload->>'enabled')::boolean,false),version=h.version+1,updated_by=uid,updated_at=now() where id=bid;
    end if;
  end if;
  insert into voku_private.audit(actor_id,action,target,reason) values(uid,'home_banner_'||action,bid::text,coalesce(v_title,b.title));
  return voku_private.home_banner_list(true);
end $$;

create function public.home_banners() returns jsonb language sql stable security invoker set search_path=''
as $$ select voku_private.home_banner_list(false); $$;
create function public.home_banner_admin() returns jsonb language sql stable security invoker set search_path=''
as $$ select voku_private.home_banner_list(true); $$;
create function public.home_banner_action(p_action text,p_payload jsonb) returns jsonb language sql security invoker set search_path=''
as $$ select voku_private.home_banner_action(p_action,p_payload); $$;
revoke all on function voku_private.is_banner_admin(),voku_private.home_banner_list(boolean),voku_private.home_banner_readable(text),
  voku_private.home_banner_uploadable(text),voku_private.home_banner_removable(text),voku_private.home_banner_action(text,jsonb),
  public.home_banners(),public.home_banner_admin(),public.home_banner_action(text,jsonb) from public,anon,authenticated;
grant usage on schema voku_private to anon;
grant execute on function voku_private.home_banner_list(boolean),voku_private.home_banner_readable(text),public.home_banners() to anon,authenticated;
grant execute on function voku_private.home_banner_uploadable(text),voku_private.home_banner_removable(text),voku_private.home_banner_action(text,jsonb),
  public.home_banner_admin(),public.home_banner_action(text,jsonb) to authenticated;
commit;
