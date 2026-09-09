-- ============================================================
-- "Dimmi come va" — i messaggi dal Profilo
--
-- Da eseguire nello SQL Editor su un database GIÀ IN FUNZIONE: aggiunge
-- e basta, non cancella niente. Chi parte da zero non ne ha bisogno,
-- perché supabase-setup.sql contiene già tutto questo.
-- ============================================================

create table if not exists public.feedback (
  id         bigserial primary key,
  member_id  uuid references public.members(id) on delete set null,
  nome       text not null,
  testo      text not null,
  letto      boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists feedback_da_leggere on public.feedback (created_at desc) where not letto;

alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
revoke all on sequence public.feedback_id_seq from anon, authenticated;

create or replace function public.api_feedback_send(p_token text, p_text text)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_me public.members; v_testo text;
begin
  v_me := public.auth_member(p_token);
  v_testo := btrim(coalesce(p_text, ''));
  if length(v_testo) < 3    then raise exception 'FEEDBACK_VUOTO'; end if;
  if length(v_testo) > 1000 then raise exception 'FEEDBACK_LUNGO'; end if;
  -- un dito fermo sul pulsante non deve poter riempire la tabella
  if (select count(*) from public.feedback
       where member_id = v_me.id and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'FEEDBACK_TROPPI';
  end if;
  insert into public.feedback (member_id, nome, testo)
  values (v_me.id, v_me.full_name, v_testo);
  return json_build_object('ok', true);
end $$;

create or replace function public.api_feedback_list(p_token text)
returns json language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
begin
  perform public.auth_admin(p_token);
  return coalesce((
    select json_agg(json_build_object('id', f.id, 'nome', f.nome, 'testo', f.testo,
                                      'created_at', f.created_at)
                    order by f.created_at desc)
      from public.feedback f
     where not f.letto), '[]'::json);
end $$;

create or replace function public.api_feedback_done(p_token text, p_id bigint)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
begin
  perform public.auth_admin(p_token);
  update public.feedback set letto = true where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  return json_build_object('ok', true);
end $$;

grant execute on function
  public.api_feedback_send(text,text),
  public.api_feedback_list(text),
  public.api_feedback_done(text,bigint)
to anon, authenticated;
