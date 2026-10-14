-- Dashboard-created or invited accounts start as ordinary, incomplete members.
-- A trusted operator must assign any administrator role separately.
begin;

create or replace function voku_private.create_member() returns trigger
language plpgsql security definer set search_path='' as $$
declare n text; affiliation record; attempt integer;
begin
  if new.raw_app_meta_data->>'provider' = 'kakao'
    or nullif(btrim(coalesce(new.raw_user_meta_data->>'nickname','')),'') is null then
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

commit;
