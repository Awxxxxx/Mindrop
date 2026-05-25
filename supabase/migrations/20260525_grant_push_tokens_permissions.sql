grant usage on schema public to authenticated, service_role;

grant select, insert, update on table public.push_tokens to authenticated;
grant select, insert, update, delete on table public.push_tokens to service_role;
