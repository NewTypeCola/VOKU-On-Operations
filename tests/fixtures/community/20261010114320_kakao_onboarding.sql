begin;

alter table voku_private.members add column profile_complete boolean not null default true;

-- OAuth users choose a community nickname after authentication. Provider profile
-- text is never used as a role, a membership assertion, or a public nickname.
create or replace function voku_private.create_member() returns trigger
language plpgsql security definer set search_path='' as $$
declare n text; affiliation record; attempt integer;
begin
  if new.raw_app_meta_data->>'provider' = 'kakao' then
    for attempt in 1..8 loop
      n := '새회원_' || substr(replace(gen_random_uuid()::text,'-',''),1,12);
      begin
        insert into public.community_profiles(id,nickname) values(new.id,n);
        exit;
      exception when unique_violation then
        if attempt=8 then raise; end if;
      end;
    end loop;
    insert into voku_private.members(id,profile_complete) values(new.id,false);
  else
    n := btrim(coalesce(new.raw_user_meta_data->>'nickname',''));
    if n !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
    select * into affiliation from voku_private.parse_affiliation(new.raw_user_meta_data->>'admission_year',new.raw_user_meta_data->>'cohort');
    insert into public.community_profiles(id,nickname) values(new.id,n);
    insert into voku_private.members(id,admission_year,cohort) values(new.id,affiliation.admission_year,affiliation.cohort);
  end if;
  return new;
end $$;

create function voku_private.require_identity() returns uuid
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
  if uid is null or not exists(
    select 1 from auth.users u where u.id=uid and
      (u.email_confirmed_at is not null or exists(
        select 1 from auth.identities i where i.user_id=u.id and i.provider='kakao'
      ))
  ) then raise exception '로그인과 이메일 또는 카카오 인증이 필요합니다.'; end if;
  if not exists(select 1 from voku_private.members where id=uid) then raise exception '회원 정보를 찾을 수 없습니다.'; end if;
  if exists(select 1 from voku_private.members where id=uid and suspended_until>now()) then raise exception '이용이 제한된 계정입니다. 내 정보에서 사유를 확인해 주세요.'; end if;
  return uid;
end $$;
revoke all on function voku_private.require_identity() from public,anon,authenticated;

create or replace function voku_private.require_member() returns uuid
language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_identity();
begin
  if not exists(select 1 from voku_private.members where id=uid and profile_complete) then
    raise exception '닉네임 설정을 먼저 완료해 주세요.';
  end if;
  return uid;
end $$;

create or replace function voku_private.profile_json(uid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p.id,'nickname',p.nickname,
    'admissionYear',m.admission_year,'cohort',m.cohort,'profileComplete',m.profile_complete,
    'providers',(select coalesce(jsonb_agg(distinct provider),'[]') from auth.identities where user_id=uid),
    'joinedAt',p.created_at,'role',m.role,'suspendedUntil',m.suspended_until,'suspensionReason',m.suspension_reason)
  from public.community_profiles p join voku_private.members m using(id) where p.id=uid;
$$;

-- Keep the existing moderation implementation private. Only profile completion
-- may run before onboarding; all other actions retain the complete-member gate.
alter function public.community_action(text,jsonb) set schema voku_private;
revoke all on function voku_private.community_action(text,jsonb) from public,anon,authenticated;
create function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid; affiliation record;
begin
  if p_action <> 'profile' then
    return voku_private.community_action(p_action,p_payload);
  end if;
  uid:=voku_private.require_identity();
  if coalesce(p_payload->>'nickname','') !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
  select * into affiliation from voku_private.parse_affiliation(
    case when p_payload ? 'admissionYear' then p_payload->>'admissionYear' else (select admission_year::text from voku_private.members where id=uid) end,
    case when p_payload ? 'cohort' then p_payload->>'cohort' else (select cohort::text from voku_private.members where id=uid) end
  );
  perform voku_private.throttle(uid,'profile',30);
  update public.community_profiles set nickname=p_payload->>'nickname' where id=uid;
  update voku_private.members set admission_year=affiliation.admission_year,cohort=affiliation.cohort,profile_complete=true where id=uid;
  return '{}'::jsonb;
end $$;
revoke all on function public.community_action(text,jsonb) from public,anon;
grant execute on function public.community_action(text,jsonb) to authenticated;
commit;
