create extension if not exists btree_gist;

create table public.marketplace_categories(
 id uuid primary key default gen_random_uuid(), parent_id uuid references public.marketplace_categories(id) on delete set null,
 slug text not null unique, name text not null, description text not null default '', active boolean not null default true,
 position integer not null default 0, created_at timestamptz not null default now()
);
alter table public.marketplace_categories enable row level security;
create policy "Active marketplace categories are public" on public.marketplace_categories for select using(active or public.is_admin());
create policy "Admins manage marketplace categories" on public.marketplace_categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
insert into public.marketplace_categories(slug,name,description,position) values
 ('hair-styling','Hairdressing and hairstyling','Cuts, styling, treatments and hair care.',1),
 ('braiding','Braiding and protective hairstyles','Braids, locs, twists and protective styling.',2),
 ('barbering','Barbering','Precision cuts, grooming and barber services.',3),
 ('nails','Nail technology','Manicures, pedicures, extensions and nail art.',4),
 ('makeup','Makeup artistry','Makeup for everyday wear, events and productions.',5),
 ('skincare','Skincare and beauty services','Facials, skincare and personal beauty treatments.',6),
 ('lashes-brows','Lash and brow services','Lash styling, brow shaping and related services.',7),
 ('other-vocational','Other approved vocational services','Additional approved trades and services.',8)
on conflict(slug) do nothing;

alter table public.professionals
 add column if not exists business_name text,
 add column if not exists profile_photo_path text,
 add column if not exists service_area text,
 add column if not exists home_service boolean not null default false,
 add column if not exists business_location boolean not null default true,
 add column if not exists public_visible boolean not null default false,
 add column if not exists profile_state text not null default 'draft' check(profile_state in ('draft','submitted','approved','published','changes_requested','suspended','archived')),
 add column if not exists cancellation_policy text not null default '',
 add column if not exists booking_preferences text not null default '',
 add column if not exists availability jsonb not null default '{}'::jsonb,
 add column if not exists updated_at timestamptz not null default now();
alter table public.professionals alter column category drop not null;
update public.professionals set profile_state=case when status='published' then 'published' when status='pending' then 'submitted' when status='archived' then 'archived' else profile_state end,public_visible=(status='published');

create table public.professional_credentials(
 id uuid primary key default gen_random_uuid(), professional_id uuid not null references public.professionals(id) on delete cascade,
 certificate_id uuid not null references public.certificates(id) on delete cascade, category_id uuid references public.marketplace_categories(id),
 advertised_as_certified boolean not null default false, created_at timestamptz not null default now(), unique(professional_id,certificate_id)
);
alter table public.certificates add column if not exists expires_at timestamptz;
alter table public.professional_credentials enable row level security;
create policy "Public verified credentials" on public.professional_credentials for select using(exists(select 1 from public.professionals p join public.certificates c on c.id=certificate_id where p.id=professional_id and p.status='published' and p.public_visible and c.revoked_at is null and (c.expires_at is null or c.expires_at>now())));
create policy "Owners manage credentials" on public.professional_credentials for all to authenticated using(exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin()) with check(exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin());
revoke insert,update,delete on public.professional_credentials from authenticated;
grant select on public.professional_credentials to anon,authenticated;

create function public.professional_add_credential(p_certificate_id uuid,p_category_id uuid,p_advertised_as_certified boolean default false) returns uuid
language plpgsql security definer set search_path=public as $$
declare professional_key uuid; credential_key uuid;
begin
 select id into professional_key from public.professionals where profile_id=auth.uid();
 if professional_key is null or not public.is_active_user() then raise exception 'Active professional profile required'; end if;
 if not exists(select 1 from public.certificates where id=p_certificate_id and student_id=auth.uid() and revoked_at is null and (expires_at is null or expires_at>now())) then raise exception 'Only your valid GlowBiz certificate can be added'; end if;
 if p_category_id is not null and not exists(select 1 from public.marketplace_categories where id=p_category_id and active) then raise exception 'Choose an active service category'; end if;
 insert into public.professional_credentials(professional_id,certificate_id,category_id,advertised_as_certified) values(professional_key,p_certificate_id,p_category_id,p_advertised_as_certified) returning id into credential_key;
 return credential_key;
end $$;
revoke all on function public.professional_add_credential(uuid,uuid,boolean) from public,anon;
grant execute on function public.professional_add_credential(uuid,uuid,boolean) to authenticated;

create table public.professional_portfolio(
 id uuid primary key default gen_random_uuid(), professional_id uuid not null references public.professionals(id) on delete cascade,
 image_path text not null, caption text not null default '', consent_confirmed boolean not null default false,
 position integer not null default 0, created_at timestamptz not null default now(), check(consent_confirmed)
);
alter table public.professional_portfolio enable row level security;
create policy "Published portfolio is public" on public.professional_portfolio for select using(exists(select 1 from public.professionals p where p.id=professional_id and p.status='published' and p.public_visible));
create policy "Professional manages own portfolio" on public.professional_portfolio for all to authenticated using(exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin()) with check(exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin());

create table public.customer_favourites(
 customer_id uuid not null references public.profiles(id) on delete cascade, professional_id uuid not null references public.professionals(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(customer_id,professional_id)
);
alter table public.customer_favourites enable row level security;
create policy "Customers manage own favourites" on public.customer_favourites for all to authenticated using(customer_id=auth.uid() and public.current_role()='customer' and public.is_active_user()) with check(customer_id=auth.uid() and public.current_role()='customer' and public.is_active_user());

create table public.service_reviews(
 id uuid primary key default gen_random_uuid(), booking_id uuid not null unique references public.bookings(id) on delete cascade,
 customer_id uuid not null references public.profiles(id), professional_id uuid not null references public.professionals(id),
 rating smallint not null check(rating between 1 and 5), body text not null default '', status text not null default 'published' check(status in ('published','hidden','reported')),
 created_at timestamptz not null default now()
);
alter table public.service_reviews enable row level security;
create policy "Published service reviews are public" on public.service_reviews for select using(status='published' or customer_id=auth.uid() or public.is_admin());
create policy "Customers review completed bookings" on public.service_reviews for insert to authenticated with check(customer_id=auth.uid() and exists(select 1 from public.bookings b where b.id=booking_id and b.customer_id=auth.uid() and b.professional_id=service_reviews.professional_id and b.status='completed') and public.current_role()='customer' and public.is_active_user());

create or replace function public.verify_certificate(p_certificate_number text) returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('certificate_number',c.certificate_number,'credential',cert.title,'course',coalesce(course.title,'Course credential'),'issued_at',c.issued_at,'valid',c.revoked_at is null and (c.expires_at is null or c.expires_at>now()),'expires_at',c.expires_at)
 from public.certificates c join public.certifications cert on cert.id=c.certification_id left join public.courses course on course.id=c.course_id where c.certificate_number=p_certificate_number
$$;
alter table public.services add column if not exists category_id uuid references public.marketplace_categories(id),
 add column if not exists certification_id uuid references public.certifications(id),
 add column if not exists advertised_as_certified boolean not null default false,
 add column if not exists pricing_unit text not null default 'per service',
 add column if not exists approval_status text not null default 'draft' check(approval_status in ('draft','pending','published','changes_requested','rejected','archived'));
update public.services set approval_status='published' where active;
drop policy if exists "Services on published profiles are public" on public.services;
create policy "Approved services on published profiles are public" on public.services for select using(
 public.is_admin() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or
 (active and approval_status='published' and exists(select 1 from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active') and
  (not advertised_as_certified or exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=services.professional_id and pc.category_id=services.category_id and pc.advertised_as_certified and cert.certification_id=services.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now()))))
);
create function public.guard_service_certification() returns trigger language plpgsql security definer set search_path=public as $$
declare prof public.professionals%rowtype;
begin
 if new.advertised_as_certified then
  select * into prof from public.professionals where id=new.professional_id;
  if new.certification_id is null or new.category_id is null or not exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=new.professional_id and pc.category_id=new.category_id and pc.advertised_as_certified and cert.certification_id=new.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now())) then raise exception 'A valid matching verified credential is required for this claim'; end if;
 end if;
 return new;
end $$;
create trigger service_certification_guard before insert or update on public.services for each row execute function public.guard_service_certification();

revoke update on public.professionals from authenticated;
grant update(display_name,headline,category,bio,location,rate_from,currency,business_name,profile_photo_path,service_area,home_service,business_location,cancellation_policy,booking_preferences,availability,updated_at) on public.professionals to authenticated;

create function public.professional_submit_profile_changes(p_display_name text,p_headline text,p_bio text,p_location text,p_service_area text,p_home_service boolean,p_business_location boolean,p_cancellation_policy text,p_booking_preferences text,p_availability jsonb) returns boolean
language plpgsql security definer set search_path=public as $$
declare pro_id uuid;
begin
 select id into pro_id from public.professionals where profile_id=auth.uid();
 if pro_id is null or not public.is_active_user() then raise exception 'Active professional profile required'; end if;
 if length(trim(coalesce(p_display_name,'')))<2 or length(p_display_name)>120 or length(trim(coalesce(p_headline,'')))<4 or length(p_headline)>180 or length(coalesce(p_bio,''))>5000 then raise exception 'Check professional profile details'; end if;
 if jsonb_typeof(coalesce(p_availability,'{}'::jsonb))<>'object' then raise exception 'Availability must be a weekly JSON object'; end if;
 update public.professionals set display_name=trim(p_display_name),business_name=trim(p_display_name),headline=trim(p_headline),bio=coalesce(p_bio,''),location=nullif(trim(p_location),''),service_area=nullif(trim(p_service_area),''),home_service=p_home_service,business_location=p_business_location,cancellation_policy=coalesce(p_cancellation_policy,''),booking_preferences=coalesce(p_booking_preferences,''),availability=coalesce(p_availability,'{}'::jsonb),profile_state='submitted',status='pending',public_visible=false,updated_at=now() where id=pro_id;
 return true;
end $$;
revoke all on function public.professional_submit_profile_changes(text,text,text,text,text,boolean,boolean,text,text,jsonb) from public,anon;
grant execute on function public.professional_submit_profile_changes(text,text,text,text,text,boolean,boolean,text,text,jsonb) to authenticated;

alter table public.bookings
 add column if not exists agreed_price numeric(12,2) not null default 0 check(agreed_price>=0),
 add column if not exists currency text not null default 'UGX',
 add column if not exists duration_minutes integer not null default 60 check(duration_minutes>0),
 add column if not exists delivery_method text not null default 'business' check(delivery_method in ('business','home_service','online')),
 add column if not exists service_location text,
 add column if not exists payment_status text not null default 'unpaid' check(payment_status in ('unpaid','pending','paid','failed','refunded')),
 add column if not exists payment_method_reference text,
 add column if not exists refund_status text not null default 'not_applicable' check(refund_status in ('not_applicable','requested','processing','refunded','rejected')),
 add column if not exists updated_at timestamptz not null default now(),
 -- Work in UTC wall-clock timestamps so the generated expression is immutable;
 -- arithmetic directly on timestamptz depends on the session time zone.
 add column if not exists booking_slot tsrange generated always as (
  tsrange(scheduled_at at time zone 'UTC',(scheduled_at at time zone 'UTC')+make_interval(mins=>duration_minutes),'[)')
 ) stored;
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings add constraint bookings_status_check check(status in ('requested','confirmed','rescheduling_requested','cancelled','completed','no_show','disputed'));
create index bookings_customer_schedule_idx on public.bookings(customer_id,scheduled_at desc);
create index bookings_professional_schedule_idx on public.bookings(professional_id,scheduled_at desc);
alter table public.bookings add constraint no_confirmed_professional_overlap exclude using gist(professional_id with =,booking_slot with &&) where(status='confirmed');

create table public.booking_history(
 id bigint generated always as identity primary key, booking_id uuid not null references public.bookings(id) on delete cascade,
 actor_id uuid references public.profiles(id), old_status text, new_status text not null, notes text not null default '', created_at timestamptz not null default now()
);
alter table public.booking_history enable row level security;
create policy "Booking participants read history" on public.booking_history for select to authenticated using(public.is_admin() or exists(select 1 from public.bookings b left join public.professionals p on p.id=b.professional_id where b.id=booking_id and (b.customer_id=auth.uid() or p.profile_id=auth.uid())));
create function public.audit_booking_status() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status then
  insert into public.booking_history(booking_id,actor_id,old_status,new_status,notes) values(new.id,auth.uid(),old.status,new.status,'');
 end if;
 new.updated_at=now();return new;
end $$;
create trigger audit_booking_status_change before update on public.bookings for each row execute function public.audit_booking_status();

create function public.marketplace_category_counts() returns table(category_id uuid,slug text,name text,description text,professional_count bigint)
language sql stable security definer set search_path=public as $$
 select cat.id,cat.slug,cat.name,cat.description,count(distinct p.id)
 from public.marketplace_categories cat left join public.professionals p on p.category=cat.name and p.status='published' and p.profile_state='published' and p.public_visible
 left join public.profiles pr on pr.id=p.profile_id and pr.account_status='active'
 where cat.active and (p.id is null or pr.id is not null)
 group by cat.id,cat.slug,cat.name,cat.description,cat.position order by cat.position
$$;
revoke all on function public.marketplace_category_counts() from public;
grant execute on function public.marketplace_category_counts() to anon,authenticated;

create function public.admin_review_professional(p_professional_id uuid,p_decision text,p_notes text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare professional_row public.professionals%rowtype;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if p_decision not in ('published','changes_requested','suspended','archived') then raise exception 'Invalid professional decision'; end if;
 select * into professional_row from public.professionals where id=p_professional_id for update;
 if professional_row.id is null then raise exception 'Professional profile not found'; end if;
 if p_decision='published' and not exists(select 1 from public.professional_credentials pc join public.certificates c on c.id=pc.certificate_id where pc.professional_id=p_professional_id and c.revoked_at is null and (c.expires_at is null or c.expires_at>now())) then raise exception 'A valid approved certificate is required before publication'; end if;
 update public.professionals set status=case when p_decision='published' then 'published'::public.review_status when p_decision='archived' then 'archived'::public.review_status else 'pending'::public.review_status end,
   profile_state=p_decision,public_visible=(p_decision='published'),updated_at=now() where id=p_professional_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'PROFESSIONAL_'||upper(p_decision),'professionals',p_professional_id,jsonb_build_object('notes',left(coalesce(p_notes,''),2000)));
 return true;
end $$;
revoke all on function public.admin_review_professional(uuid,text,text) from public,anon;
grant execute on function public.admin_review_professional(uuid,text,text) to authenticated;

create function public.customer_request_booking(p_professional_id uuid,p_service_id uuid,p_scheduled_at timestamptz,p_notes text default '',p_delivery_method text default 'business',p_service_location text default null) returns uuid
language plpgsql security definer set search_path=public as $$
declare service_row public.services%rowtype; customer_key uuid; booking_key uuid; professional_row public.professionals%rowtype;
begin
 customer_key:=auth.uid();
 if customer_key is null or not exists(select 1 from public.profiles where id=customer_key and role='customer' and account_status='active') then raise exception 'Active customer account required'; end if;
 select * into professional_row from public.professionals where id=p_professional_id and status='published' and profile_state='published' and public_visible;
 if professional_row.id is null then raise exception 'Professional profile is not available'; end if;
 select * into service_row from public.services where id=p_service_id and professional_id=p_professional_id and active;
 if service_row.id is null then raise exception 'Choose an available service'; end if;
 if p_scheduled_at<now()+interval '1 hour' or p_scheduled_at>now()+interval '365 days' then raise exception 'Choose a booking time at least one hour from now'; end if;
 if p_delivery_method not in ('business','home_service','online') or p_delivery_method='home_service' and not professional_row.home_service or p_delivery_method='business' and not professional_row.business_location then raise exception 'This delivery method is not available'; end if;
 if length(coalesce(p_notes,''))>1000 or length(coalesce(p_service_location,''))>500 then raise exception 'Booking details are too long'; end if;
 if professional_row.availability<>'{}'::jsonb then
  declare day_key text:=lower(to_char(p_scheduled_at at time zone 'Africa/Kampala','Dy')); slot_key text:=to_char(p_scheduled_at at time zone 'Africa/Kampala','HH24:MI'); matched boolean:=false; item jsonb;
  begin
   for item in select value from jsonb_array_elements(coalesce(professional_row.availability->day_key,'[]'::jsonb)) loop
    if slot_key>=(item->>'start') and to_char((p_scheduled_at at time zone 'Africa/Kampala')+make_interval(mins=>service_row.duration_minutes),'HH24:MI')<=(item->>'end') then matched:=true;exit;end if;
   end loop;
   if not matched then raise exception 'Choose a time within the professional availability'; end if;
  end;
 else raise exception 'This professional has not set availability yet'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_professional_id::text||':'||date_trunc('day',p_scheduled_at)::text,0));
 insert into public.bookings(customer_id,professional_id,service_id,scheduled_at,status,notes,agreed_price,currency,duration_minutes,delivery_method,service_location)
 values(customer_key,p_professional_id,p_service_id,p_scheduled_at,'requested',coalesce(p_notes,''),coalesce(service_row.price,professional_row.rate_from,0),professional_row.currency,service_row.duration_minutes,p_delivery_method,p_service_location) returning id into booking_key;
 insert into public.booking_history(booking_id,actor_id,new_status,notes) values(booking_key,customer_key,'requested','Booking requested');
 return booking_key;
end $$;
revoke all on function public.customer_request_booking(uuid,uuid,timestamptz,text,text,text) from public,anon;
grant execute on function public.customer_request_booking(uuid,uuid,timestamptz,text,text,text) to authenticated;

create function public.professional_update_booking(p_booking_id uuid,p_decision text,p_new_time timestamptz default null,p_notes text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare booking_row public.bookings%rowtype; professional_key uuid;
begin
 select b.* into booking_row from public.bookings b join public.professionals p on p.id=b.professional_id where b.id=p_booking_id and p.profile_id=auth.uid() for update;
 if booking_row.id is null or not public.is_active_user() then raise exception 'Professional booking access required'; end if;
 select id into professional_key from public.professionals where profile_id=auth.uid();
 perform pg_advisory_xact_lock(hashtextextended(professional_key::text||':'||date_trunc('day',coalesce(p_new_time,booking_row.scheduled_at))::text,0));
 if p_decision='confirm' and booking_row.status='requested' then update public.bookings set status='confirmed' where id=p_booking_id;
 elsif p_decision='reject' and booking_row.status='requested' then update public.bookings set status='cancelled' where id=p_booking_id;
 elsif p_decision='reschedule' and booking_row.status in ('requested','confirmed') and p_new_time>now()+interval '1 hour' then update public.bookings set scheduled_at=p_new_time,status='rescheduling_requested' where id=p_booking_id;
 elsif p_decision='complete' and booking_row.status='confirmed' then update public.bookings set status='completed' where id=p_booking_id;
 else raise exception 'This booking action is not available'; end if;
 update public.booking_history set notes=left(coalesce(p_notes,''),1000) where id=(select max(id) from public.booking_history where booking_id=p_booking_id and actor_id=auth.uid());
 return true;
end $$;
revoke all on function public.professional_update_booking(uuid,text,timestamptz,text) from public,anon;
grant execute on function public.professional_update_booking(uuid,text,timestamptz,text) to authenticated;
create function public.customer_cancel_booking(p_booking_id uuid,p_reason text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare b public.bookings%rowtype;
begin
 select * into b from public.bookings where id=p_booking_id and customer_id=auth.uid() for update;
 if b.id is null or not public.is_active_user() or public.current_role()<>'customer' then raise exception 'Booking not found'; end if;
 if b.status not in ('requested','confirmed','rescheduling_requested') or length(coalesce(p_reason,''))>1000 then raise exception 'This booking cannot be cancelled'; end if;
 update public.bookings set status='cancelled' where id=b.id;
 update public.booking_history set notes=left(coalesce(p_reason,''),1000) where id=(select max(id) from public.booking_history where booking_id=b.id and actor_id=auth.uid());
 return true;
end $$;
revoke all on function public.customer_cancel_booking(uuid,text) from public,anon;
grant execute on function public.customer_cancel_booking(uuid,text) to authenticated;
revoke insert,update on public.bookings from authenticated;
grant select on public.bookings to authenticated;

create table public.marketplace_conversations(
 id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.profiles(id) on delete cascade,
 professional_id uuid not null references public.professionals(id) on delete cascade, booking_id uuid references public.bookings(id) on delete set null,
 reported boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index marketplace_conversation_no_booking_unique on public.marketplace_conversations(customer_id,professional_id) where booking_id is null;
create table public.marketplace_messages(
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.marketplace_conversations(id) on delete cascade,
 sender_id uuid not null references public.profiles(id) on delete cascade, body text not null check(length(body) between 1 and 5000),
 read_at timestamptz, created_at timestamptz not null default now()
);
alter table public.marketplace_conversations enable row level security;alter table public.marketplace_messages enable row level security;
create policy "Marketplace conversation participants read" on public.marketplace_conversations for select to authenticated using(public.is_admin() or (public.is_active_user() and (customer_id=auth.uid() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()))));
create policy "Marketplace message participants read" on public.marketplace_messages for select to authenticated using(public.is_admin() or (public.is_active_user() and exists(select 1 from public.marketplace_conversations c left join public.professionals p on p.id=c.professional_id where c.id=conversation_id and (c.customer_id=auth.uid() or p.profile_id=auth.uid()))));
create policy "Marketplace participants send messages" on public.marketplace_messages for insert to authenticated with check(sender_id=auth.uid() and exists(select 1 from public.marketplace_conversations c join public.professionals p on p.id=c.professional_id where c.id=conversation_id and (c.customer_id=auth.uid() or p.profile_id=auth.uid()) and public.is_active_user()));
create index marketplace_conversations_customer_idx on public.marketplace_conversations(customer_id,updated_at desc);
create index marketplace_conversations_professional_idx on public.marketplace_conversations(professional_id,updated_at desc);
create index marketplace_messages_conversation_idx on public.marketplace_messages(conversation_id,created_at);
create function public.touch_marketplace_conversation() returns trigger language plpgsql security definer set search_path=public as $$
begin update public.marketplace_conversations set updated_at=now() where id=new.conversation_id;return new;end $$;
create trigger marketplace_message_activity after insert on public.marketplace_messages for each row execute function public.touch_marketplace_conversation();
create index professionals_public_search_idx on public.professionals(status,profile_state,category,location) where public_visible;
create index services_marketplace_search_idx on public.services(professional_id,active,price);

create function public.marketplace_mark_read(p_conversation_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_active_user() or not exists(select 1 from public.marketplace_conversations c left join public.professionals p on p.id=c.professional_id where c.id=p_conversation_id and (c.customer_id=auth.uid() or p.profile_id=auth.uid())) then raise exception 'Conversation access required'; end if;
 update public.marketplace_messages set read_at=now() where conversation_id=p_conversation_id and sender_id<>auth.uid() and read_at is null;return true;
end $$;
revoke all on function public.marketplace_mark_read(uuid) from public,anon;
grant execute on function public.marketplace_mark_read(uuid) to authenticated;
create function public.marketplace_report_conversation(p_conversation_id uuid,p_reason text default '') returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_active_user() or length(coalesce(p_reason,''))>1000 or not exists(select 1 from public.marketplace_conversations c left join public.professionals p on p.id=c.professional_id where c.id=p_conversation_id and (c.customer_id=auth.uid() or p.profile_id=auth.uid())) then raise exception 'Conversation access required'; end if;
 update public.marketplace_conversations set reported=true,updated_at=now() where id=p_conversation_id;insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'MARKETPLACE_CONVERSATION_REPORTED','marketplace_conversations',p_conversation_id,jsonb_build_object('reason',left(coalesce(p_reason,''),1000)));return true;
end $$;
revoke all on function public.marketplace_report_conversation(uuid,text) from public,anon;
grant execute on function public.marketplace_report_conversation(uuid,text) to authenticated;

drop policy if exists "Published professionals readable" on public.professionals;
create policy "Eligible published professional profiles are public" on public.professionals for select using(
 public.is_admin() or profile_id=auth.uid() or (status='published' and profile_state='published' and public_visible and exists(select 1 from public.profiles pr where pr.id=profile_id and pr.account_status='active'))
);
drop policy if exists "Active services readable" on public.services;
create policy "Services on published profiles are public" on public.services for select using(
 public.is_admin() or exists(select 1 from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or
 (active and approval_status='published' and exists(select 1 from public.professionals p join public.profiles pr on pr.id=p.profile_id where p.id=professional_id and p.status='published' and p.profile_state='published' and p.public_visible and pr.account_status='active') and
  (not advertised_as_certified or exists(select 1 from public.professional_credentials pc join public.certificates cert on cert.id=pc.certificate_id where pc.professional_id=services.professional_id and pc.category_id=services.category_id and pc.advertised_as_certified and cert.certification_id=services.certification_id and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now()))))
);

create function public.student_create_professional_profile(p_certificate_id uuid,p_display_name text,p_headline text,p_category text) returns uuid
language plpgsql security definer set search_path=public as $$
declare certificate_row public.certificates%rowtype; profile_key uuid; professional_key uuid; category_key uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role in ('student','tutor','customer') and account_status='active') then raise exception 'Active account required'; end if;
 if length(trim(coalesce(p_display_name,'')))<2 or length(p_display_name)>120 or length(trim(coalesce(p_headline,'')))<4 or length(p_headline)>180 then raise exception 'Enter a valid business name and headline'; end if;
 select cert.* into certificate_row from public.certificates cert join public.certifications cr on cr.id=cert.certification_id where cert.id=p_certificate_id and cert.student_id=auth.uid() and cert.revoked_at is null and (cert.expires_at is null or cert.expires_at>now());
 if certificate_row.id is null then raise exception 'An approved, valid course certificate is required'; end if;
 select id into category_key from public.marketplace_categories where name=p_category and active;
 if category_key is null then raise exception 'Choose an approved marketplace category'; end if;
 if exists(select 1 from public.professionals where profile_id=auth.uid()) then raise exception 'A professional profile already exists'; end if;
 profile_key:=auth.uid();
 insert into public.professionals(profile_id,display_name,business_name,headline,category,bio,status,profile_state,public_visible)
 values(profile_key,trim(p_display_name),trim(p_display_name),trim(p_headline),trim(p_category),trim(p_headline),'pending','submitted',false) returning id into professional_key;
 insert into public.professional_credentials(professional_id,certificate_id,category_id,advertised_as_certified) values(professional_key,p_certificate_id,category_key,true);
 return professional_key;
end $$;
revoke all on function public.student_create_professional_profile(uuid,text,text,text) from public,anon;
grant execute on function public.student_create_professional_profile(uuid,text,text,text) to authenticated;

create function public.marketplace_start_conversation(p_professional_id uuid,p_body text) returns uuid
language plpgsql security definer set search_path=public as $$
declare conversation_key uuid; professional_owner uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='customer' and account_status='active') then raise exception 'Active customer account required'; end if;
 select profile_id into professional_owner from public.professionals where id=p_professional_id and status='published' and profile_state='published' and public_visible;
 if professional_owner is null then raise exception 'Professional profile is not available'; end if;
 if length(trim(coalesce(p_body,'')))<1 or length(p_body)>5000 then raise exception 'Message must be between 1 and 5000 characters'; end if;
 insert into public.marketplace_conversations(customer_id,professional_id) values(auth.uid(),p_professional_id) on conflict(customer_id,professional_id) where booking_id is null do update set updated_at=now() returning id into conversation_key;
 insert into public.marketplace_messages(conversation_id,sender_id,body) values(conversation_key,auth.uid(),left(trim(p_body),5000));
 return conversation_key;
end $$;
revoke all on function public.marketplace_start_conversation(uuid,text) from public,anon;
grant execute on function public.marketplace_start_conversation(uuid,text) to authenticated;
