-- Admin managed marketplace transitions, user initiated account requests and support inbox.
create table public.account_action_requests(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 action text not null check(action in ('delete_account','reset_profile')), reason text not null default '' check(length(reason)<=2000),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, created_at timestamptz not null default now()
);
create unique index one_pending_account_action_per_user on public.account_action_requests(user_id,action) where status='pending';
alter table public.account_action_requests enable row level security;
create policy "Users read own account requests; admins manage requests" on public.account_action_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
revoke insert,update,delete on public.account_action_requests from anon,authenticated;

create table public.support_conversations(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 subject text not null check(length(subject) between 3 and 120), status text not null default 'open' check(status in ('open','closed')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.support_messages(
 id uuid primary key default gen_random_uuid(), conversation_id uuid not null references public.support_conversations(id) on delete cascade,
 sender_id uuid not null references public.profiles(id) on delete cascade, body text not null check(length(body) between 1 and 5000),
 created_at timestamptz not null default now(), read_at timestamptz
);
alter table public.support_conversations enable row level security;
alter table public.support_messages enable row level security;
create policy "Support conversation participants or admins read" on public.support_conversations for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "Support message participants or admins read" on public.support_messages for select to authenticated using(public.is_admin() or exists(select 1 from public.support_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
revoke insert,update,delete on public.support_conversations,public.support_messages from anon,authenticated;
create index support_conversations_queue_idx on public.support_conversations(status,updated_at desc);
create index support_messages_thread_idx on public.support_messages(conversation_id,created_at);

create function public.admin_update_marketplace_booking(p_booking_id uuid,p_status text,p_notes text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare booking_row public.bookings%rowtype;
begin
 if not public.is_admin() or not public.is_active_user() then raise exception 'Administrator access required'; end if;
 if p_status not in ('confirmed','rescheduling_requested','cancelled','completed','no_show','disputed') or length(coalesce(p_notes,''))>2000 then raise exception 'Invalid booking decision'; end if;
 select * into booking_row from public.bookings where id=p_booking_id for update;
 if booking_row.id is null then raise exception 'Booking not found'; end if;
 if booking_row.status='completed' and p_status not in ('disputed') then raise exception 'Completed bookings cannot be changed'; end if;
 update public.bookings set status=p_status where id=p_booking_id;
 insert into public.booking_history(booking_id,actor_id,old_status,new_status,notes) values(p_booking_id,auth.uid(),booking_row.status,p_status,left(coalesce(p_notes,''),2000));
 return true;
end $$;
revoke all on function public.admin_update_marketplace_booking(uuid,text,text) from public,anon;
grant execute on function public.admin_update_marketplace_booking(uuid,text,text) to authenticated;
