-- Uploaded avatars are public on posts. Introductions belong only to the owner.
-- Prepared locally; production application is a separate release step.
begin;
alter table public.community_profiles add column avatar_path text
  check (avatar_path is null or avatar_path ~ ('^' || id::text || '/[a-f0-9-]{36}\.jpg$'));
alter table voku_private.members add column introduction text not null default ''
  check (char_length(introduction) <= 300);
alter table voku_private.members add column avatar_customized boolean not null default false;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('profile-photos','profile-photos',true,262144,array['image/jpeg']);

create function voku_private.profile_photo_uploadable(object_name text) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member();
begin
  -- Serialize each owner's quota check, including parallel Storage uploads.
  perform 1 from public.community_profiles where id=uid for update;
  if (select count(*) from storage.objects where bucket_id='profile-photos' and name like uid::text || '/%') >= 8 then
    raise exception '사진 저장 요청이 많아요. 잠시 후 다시 시도해 주세요.';
  end if;
  return object_name ~ ('^' || uid::text || '/[a-f0-9-]{36}\.jpg$');
end $$;
create function voku_private.profile_photo_removable(object_name text) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare current_photo text; uid uuid:=auth.uid();
begin
  select avatar_path into current_photo from public.community_profiles where id=uid for update;
  return found and object_name like uid::text || '/%' and current_photo is distinct from object_name;
end
$$;
revoke all on function voku_private.profile_photo_uploadable(text),voku_private.profile_photo_removable(text) from public,anon,authenticated;
grant execute on function voku_private.profile_photo_uploadable(text),voku_private.profile_photo_removable(text) to authenticated;
create policy profile_photo_insert on storage.objects for insert to authenticated with check
  (bucket_id='profile-photos' and voku_private.profile_photo_uploadable(name));
create policy profile_photo_select_own on storage.objects for select to authenticated using
  (bucket_id='profile-photos' and name like (select auth.uid())::text || '/%');
create policy profile_photo_delete_unused on storage.objects for delete to authenticated using
  (bucket_id='profile-photos' and voku_private.profile_photo_removable(name));
-- No UPDATE policy: each upload has an immutable path, preventing stale caches
-- and a caller from replacing another member's photo through upsert.

alter function voku_private.profile_json(uuid) rename to profile_json_before_photo;
create function voku_private.profile_json(uid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select voku_private.profile_json_before_photo(uid)
    || jsonb_build_object('avatarPath',p.avatar_path)
    || case when uid=(select auth.uid()) then jsonb_build_object('introduction',m.introduction,'avatarCustomized',m.avatar_customized) else '{}'::jsonb end
  from public.community_profiles p join voku_private.members m using(id) where p.id=uid;
$$;
revoke all on function voku_private.profile_json_before_photo(uuid),voku_private.profile_json(uuid) from public,anon,authenticated;

alter function voku_private.post_json(uuid) rename to post_json_before_profile_photo;
create function voku_private.post_json(pid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select voku_private.post_json_before_profile_photo(pid)
    || jsonb_build_object('authorAvatarPath',case when voku_private.post_readable(pid) then cp.avatar_path else null end)
  from public.community_posts p join public.community_profiles cp on cp.id=p.author_id where p.id=pid;
$$;
revoke all on function voku_private.post_json_before_profile_photo(uuid),voku_private.post_json(uuid) from public,anon,authenticated;

alter function public.community_action(text,jsonb) rename to action_before_profile_photo;
alter function public.action_before_profile_photo(text,jsonb) set schema voku_private;
revoke all on function voku_private.action_before_profile_photo(text,jsonb) from public,anon,authenticated;
create function voku_private.action_with_profile_photo(p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid; result jsonb; photo text; intro text;
begin
  if p_action <> 'profile' then return voku_private.action_before_profile_photo(p_action,p_payload); end if;
  uid:=voku_private.require_identity();
  perform 1 from public.community_profiles where id=uid for update;
  if p_payload ? 'introduction' then
    if jsonb_typeof(p_payload->'introduction') <> 'string' then raise exception '소개를 확인해 주세요.'; end if;
    intro:=btrim(p_payload->>'introduction');
    if char_length(intro)>300 then raise exception '소개는 300자 이내로 입력해 주세요.'; end if;
  end if;
  if p_payload ? 'avatarPath' then
    photo:=p_payload->>'avatarPath';
    if photo is not null and (
      photo !~ ('^' || uid::text || '/[a-f0-9-]{36}\.jpg$') or not exists(
        select 1 from storage.objects where bucket_id='profile-photos' and name=photo
          and metadata->>'mimetype'='image/jpeg'
          and (metadata->>'size')::bigint between 1 and 262144
      )
    ) then raise exception '프로필 사진을 다시 선택해 주세요.'; end if;
  end if;
  -- Preserve affiliation, nickname validation, onboarding, suspension and throttle.
  -- A failure below rolls back the entire edit, including nickname changes.
  result:=voku_private.action_before_profile_photo(p_action,p_payload);
  if p_payload ? 'introduction' then update voku_private.members set introduction=intro where id=uid; end if;
  if p_payload ? 'avatarPath' then
    update public.community_profiles set avatar_path=photo where id=uid;
    update voku_private.members set avatar_customized=true where id=uid;
  end if;
  return result;
end $$;
create function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$
  select voku_private.action_with_profile_photo(p_action,p_payload);
$$;
revoke all on function voku_private.action_with_profile_photo(text,jsonb),public.community_action(text,jsonb) from public,anon,authenticated;
grant execute on function voku_private.action_with_profile_photo(text,jsonb),public.community_action(text,jsonb) to authenticated;
commit;
