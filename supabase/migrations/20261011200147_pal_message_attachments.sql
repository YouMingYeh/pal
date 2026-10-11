-- Private media is linked to one ordinary human message in the same transaction.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('message-attachments','message-attachments',false,4194304,array['image/jpeg','audio/mp4'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy pal_message_media_service_only on storage.objects as restrictive for all to anon,authenticated
  using(bucket_id<>'message-attachments') with check(bucket_id<>'message-attachments');
create policy pal_message_media_bucket_service_only on storage.buckets as restrictive for all to anon,authenticated
  using(id<>'message-attachments') with check(id<>'message-attachments');

create unique index messages_id_group_unique on public.messages(id,group_id);
create table public.message_attachments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  message_id uuid not null unique,
  uploader_id uuid not null references auth.users(id) on delete cascade,
  client_id uuid not null,
  object_path text not null unique,
  kind text not null check(kind in ('image','audio')),
  mime_type text not null,
  byte_size bigint not null check(byte_size between 1 and 4194304),
  width integer,
  height integer,
  duration_ms integer,
  input_sha256 text not null check(input_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  foreign key(message_id,group_id) references public.messages(id,group_id) on delete cascade,
  unique(group_id,uploader_id,client_id),
  check(object_path ~ ('^'||group_id::text||'/'||uploader_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'||case when kind='image' then '\.jpg$' else '\.m4a$' end)),
  check((kind='image' and mime_type='image/jpeg' and width is not null and width between 1 and 1024 and height is not null and height between 1 and 1024 and duration_ms is null)
    or (kind='audio' and mime_type='audio/mp4' and width is null and height is null and duration_ms is not null and duration_ms between 1 and 60000))
);
alter table public.message_attachments enable row level security;
revoke all on public.message_attachments from public,anon,authenticated;
grant select on public.message_attachments to authenticated;
grant all on public.message_attachments to service_role;
create policy members_read_attachments on public.message_attachments for select to authenticated
  using(group_id in (select private.my_group_ids()));
create index message_attachments_group_idx on public.message_attachments(group_id);

create function private.send_attachment(
  p_group_id uuid,p_user_id uuid,p_client_id uuid,p_object_path text,p_kind text,p_mime_type text,
  p_byte_size bigint,p_width integer,p_height integer,p_duration_ms integer,p_sha256 text,
  p_body text default null,p_reply_to_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.messages; a public.message_attachments; body text; prior_sub text;
begin
  if current_setting('role',true)<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  perform 1 from public.groups where id=p_group_id for update;
  if not found or p_user_id is null or not exists(select 1 from public.group_members where group_id=p_group_id and user_id=p_user_id) then
    raise exception 'Group membership required' using errcode='42501';
  end if;
  if p_client_id is null or p_kind is null or p_kind not in ('image','audio') or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_byte_size is null or p_byte_size not between 1 and 4194304 then
    raise exception 'Valid attachment identity, hash, kind and size required' using errcode='22023';
  end if;
  if p_object_path is null or p_object_path !~ ('^'||p_group_id::text||'/'||p_user_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'||case when p_kind='image' then '\.jpg$' else '\.m4a$' end) then
    raise exception 'Group and owner scoped UUID media path required' using errcode='22023';
  end if;
  if p_kind='image' then
    if p_mime_type is distinct from 'image/jpeg' or p_width is null or p_width not between 1 and 1024 or p_height is null or p_height not between 1 and 1024 or p_duration_ms is not null then
      raise exception 'Normalized JPEG dimensions required' using errcode='22023';
    end if;
  elsif p_mime_type is distinct from 'audio/mp4' or p_width is not null or p_height is not null or p_duration_ms is null or p_duration_ms not between 1 and 60000 then
    raise exception 'M4A voice recording of at most 60 seconds required' using errcode='22023';
  end if;
  body:=coalesce(nullif(btrim(p_body),''),case when p_kind='image' then 'Photo' else 'Voice message' end);
  if length(body)>4000 then raise exception 'Caption too long' using errcode='22023'; end if;
  select * into m from public.messages where group_id=p_group_id and sender_id=p_user_id and client_id=p_client_id;
  if found then
    select * into a from public.message_attachments where message_id=m.id;
    if not found or a.kind<>p_kind or a.input_sha256<>p_sha256 or m.body<>body or m.reply_to_id is distinct from p_reply_to_id then
      raise exception 'Client ID already used for another message or attachment' using errcode='22023';
    end if;
    return jsonb_build_object('message',to_jsonb(m),'attachment',to_jsonb(a),'uploaded_path_used',a.object_path=p_object_path);
  end if;
  -- The service has already authorized this requester. Reuse the existing human
  -- send path without changing its auth, queueing, URL or reply semantics.
  prior_sub:=current_setting('request.jwt.claim.sub',true);
  perform set_config('request.jwt.claim.sub',p_user_id::text,true);
  begin
    m:=private.send_message(p_group_id,body,p_client_id,p_reply_to_id);
  exception when others then
    perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
    raise;
  end;
  perform set_config('request.jwt.claim.sub',coalesce(prior_sub,''),true);
  insert into public.message_attachments(group_id,message_id,uploader_id,client_id,object_path,kind,mime_type,byte_size,width,height,duration_ms,input_sha256)
  values(p_group_id,m.id,p_user_id,p_client_id,p_object_path,p_kind,p_mime_type,p_byte_size,p_width,p_height,p_duration_ms,p_sha256) returning * into a;
  return jsonb_build_object('message',to_jsonb(m),'attachment',to_jsonb(a),'uploaded_path_used',true);
end $$;
create function public.send_attachment(
  p_group_id uuid,p_user_id uuid,p_client_id uuid,p_object_path text,p_kind text,p_mime_type text,
  p_byte_size bigint,p_width integer,p_height integer,p_duration_ms integer,p_sha256 text,
  p_body text default null,p_reply_to_id uuid default null
) returns jsonb language sql set search_path='' as $$
  select private.send_attachment(p_group_id,p_user_id,p_client_id,p_object_path,p_kind,p_mime_type,p_byte_size,p_width,p_height,p_duration_ms,p_sha256,p_body,p_reply_to_id)
$$;
revoke all on function public.send_attachment(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,text,uuid),private.send_attachment(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,text,uuid) from public,anon,authenticated;
grant execute on function public.send_attachment(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,text,uuid),private.send_attachment(uuid,uuid,uuid,text,text,text,bigint,integer,integer,integer,text,text,uuid) to service_role;
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.message_attachments;
  end if;
end $$;
