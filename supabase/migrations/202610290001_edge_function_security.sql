-- Shared, atomic rate limiting for privileged Supabase Edge Functions.
create table if not exists public.edge_rate_limits (
  rate_key text primary key check (length(rate_key) between 32 and 128),
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0),
  updated_at timestamptz not null default now()
);
alter table public.edge_rate_limits enable row level security;
revoke all on public.edge_rate_limits from public, anon, authenticated;
grant all on public.edge_rate_limits to service_role;

create or replace function public.consume_edge_rate_limit(
  p_rate_key text,
  p_limit integer default 30,
  p_window_seconds integer default 3600
) returns boolean
language plpgsql security definer set search_path=public,pg_temp as $$
declare allowed boolean;
begin
  if p_rate_key is null or length(p_rate_key) not between 32 and 128
    or p_limit < 1 or p_limit > 1000 or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'Invalid rate limit parameters';
  end if;
  insert into public.edge_rate_limits(rate_key,window_started_at,request_count,updated_at)
  values(p_rate_key,now(),1,now())
  on conflict(rate_key) do update set
    window_started_at=case when public.edge_rate_limits.window_started_at <= now()-make_interval(secs=>p_window_seconds) then now() else public.edge_rate_limits.window_started_at end,
    request_count=case when public.edge_rate_limits.window_started_at <= now()-make_interval(secs=>p_window_seconds) then 1 else public.edge_rate_limits.request_count+1 end,
    updated_at=now()
  returning request_count <= p_limit into allowed;
  return allowed;
end $$;
revoke all on function public.consume_edge_rate_limit(text,integer,integer) from public,anon,authenticated;
grant execute on function public.consume_edge_rate_limit(text,integer,integer) to service_role;

create index if not exists edge_rate_limits_updated_at_idx on public.edge_rate_limits(updated_at);
