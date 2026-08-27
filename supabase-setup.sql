-- ============================================================
-- CAMBIO TURNI — setup database Supabase (v2)
-- Incolla TUTTO nello SQL Editor di Supabase ed esegui.
-- Ricrea le tabelle da zero: cancella eventuali dati esistenti.
--
-- Strumento tra colleghi, senza manager e senza approvazioni:
--   1. chiedo   → "il 31 agosto vorrei iniziare alle 9:30"   (aperta)
--   2. un collega dice "ci penso io" e comunica il suo orario  (presa)
--   3. il cambio vero si fa su UKG
--   4. chi ha chiesto o chi ha accettato segna "risolto"       (risolta)
-- Chi ha chiesto e chi ha accettato possono sempre tornare
-- all'inizio (la richiesta torna aperta) o annullare.
--
-- Accesso semplice (sicurezza bassa, come richiesto):
--   registrazione = nome e cognome + un codice di 6 cifre scelto da te
--   accesso       = scegli il tuo nome dalla lista + codice di 6 cifre
--
-- Quel poco di igiene che costa zero e c'è comunque:
--   * il codice non è salvato in chiaro (hash bcrypt)
--   * token di sessione casuali da 32 byte (salvati come SHA-256)
--   * tutte le scritture passano da funzioni SECURITY DEFINER
--   * RLS attiva e permessi revocati alla chiave pubblica anon
--   * max 10 tentativi sbagliati in 15 minuti per persona
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- Pulizia (anche delle tabelle della v1)
-- ------------------------------------------------------------
drop table if exists public.swap_declines  cascade;
drop table if exists public.swaps          cascade;
drop table if exists public.requests       cascade;
drop table if exists public.sessions       cascade;
drop table if exists public.login_attempts cascade;
drop table if exists public.members        cascade;
drop table if exists public.app_settings   cascade;
drop table if exists public.access_codes   cascade;

-- ------------------------------------------------------------
-- Tabelle
-- ------------------------------------------------------------

-- Le persone che usano l'app (~100)
create table public.members (
  id         uuid primary key default gen_random_uuid(),
  full_name  text not null,
  pin_hash   text not null,                  -- bcrypt del codice a 6 cifre
  role       text not null default 'member' check (role in ('member','admin')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_login timestamptz
);
-- due "Mario Rossi" non possono coesistere: il nome è l'identità
create unique index members_name_uniq on public.members (lower(btrim(full_name)));

-- Sessioni: un token per dispositivo, valido 90 giorni
create table public.sessions (
  token_hash text primary key,               -- sha256 del token
  member_id  uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 days'
);
create index sessions_member_idx on public.sessions (member_id);

-- Tentativi di accesso falliti, per il limite anti-tentativi
create table public.login_attempts (
  id        bigserial primary key,
  member_id uuid not null references public.members(id) on delete cascade,
  at        timestamptz not null default now()
);
create index login_attempts_idx on public.login_attempts (member_id, at desc);

-- Le richieste, sempre riferite a una sola giornata:
--   kind = 'orario' → vorrei iniziare a un'altra ora
--   kind = 'off'    → vorrei il giorno libero, qualcuno copre il mio turno
create table public.swaps (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references public.members(id) on delete cascade,
  target_date date not null,
  kind        text not null default 'orario' check (kind in ('orario','off')),
  from_time   time,                          -- il turno che ho ora (facoltativo)
  to_time     time,                          -- l'orario a cui vorrei iniziare (solo kind='orario')
  -- solo kind='off': i giorni che offro in cambio, con l'ora in cui posso
  -- entrare. Formato: [{"d":"2026-09-01","t":"09:00"}, ...]
  offers      jsonb not null default '[]'::jsonb,
  status      text not null default 'aperta'
              check (status in ('aperta','presa','risolta','annullata')),
  taker_id    uuid references public.members(id) on delete set null,
  taker_time  time,                          -- l'orario di chi dice "ci penso io"
  taker_note  text,                          -- commento facoltativo di chi accetta
  taken_at    timestamptz,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- una sola richiesta viva per persona e giorno
create unique index swaps_one_active
  on public.swaps (author_id, target_date)
  where status in ('aperta','presa');
create index swaps_date_idx on public.swaps (target_date);

-- "Non posso": segnale facoltativo, così chi chiede sa chi ha già guardato
create table public.swap_declines (
  swap_id   uuid not null references public.swaps(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  at        timestamptz not null default now(),
  primary key (swap_id, member_id)
);

-- ------------------------------------------------------------
-- Permessi: la chiave anon è pubblica, quindi non tocca le tabelle.
-- Tutto passa dalle funzioni api_* qui sotto.
-- (Supabase concede di default tutto su public: qui si revoca.)
-- ------------------------------------------------------------
alter table public.members        enable row level security;
alter table public.sessions       enable row level security;
alter table public.login_attempts enable row level security;
alter table public.swaps          enable row level security;
alter table public.swap_declines  enable row level security;

revoke all on public.members        from anon, authenticated;
revoke all on public.sessions       from anon, authenticated;
revoke all on public.login_attempts from anon, authenticated;
revoke all on public.swaps          from anon, authenticated;
revoke all on public.swap_declines  from anon, authenticated;
revoke all on sequence public.login_attempts_id_seq from anon, authenticated;

-- Nessuna policy = nessun accesso diretto alle tabelle. È voluto.

-- ------------------------------------------------------------
-- Utility
-- ------------------------------------------------------------

-- La settimana va da SABATO a VENERDÌ (serve al calendario)
create or replace function public.week_start(d date)
returns date language sql immutable as $$
  select d - ((extract(dow from d)::int + 1) % 7)
$$;

create or replace function public.member_json(m public.members)
returns json language sql immutable as $$
  select json_build_object(
    'id', m.id, 'full_name', m.full_name, 'role', m.role, 'active', m.active)
$$;

-- Crea una sessione e restituisce il token in chiaro (l'unica volta)
create or replace function public.new_session(p_member uuid)
returns text language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_token text;
begin
  v_token := encode(gen_random_bytes(32), 'hex');
  delete from public.sessions where expires_at < now();
  insert into public.sessions (token_hash, member_id)
  values (encode(digest(v_token, 'sha256'), 'hex'), p_member);
  return v_token;
end $$;

-- Traduce un token in un membro attivo. Solleva eccezione se non vale.
create or replace function public.auth_member(p_token text)
returns public.members language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  select m.* into v_member
    from public.sessions s
    join public.members m on m.id = s.member_id
   where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and s.expires_at > now()
     and m.active;
  if not found then raise exception 'NOT_AUTHENTICATED'; end if;
  return v_member;
end $$;

create or replace function public.auth_admin(p_token text)
returns public.members language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  if v_member.role <> 'admin' then raise exception 'NOT_ADMIN'; end if;
  return v_member;
end $$;

-- Le richieste in formato JSON, viste da una persona precisa.
-- Usata sia dal calendario sia dalla bacheca.
--
-- PRIVACY: chi ha accettato (nome, orario, commento) lo vedono solo i due
-- interessati. Per tutti gli altri la richiesta risulta semplicemente
-- "in pending", senza dire chi se n'è occupato.
create or replace function public.swaps_json(
  p_me uuid, p_from date default null, p_to date default null)
returns json language sql stable security definer set search_path = pg_catalog, public, extensions as $$
  select coalesce(json_agg(x order by x.target_date, x.created_at), '[]'::json)
  from (
    select s.id, s.author_id, a.full_name as author_name, s.target_date, s.kind,
           to_char(s.from_time,  'HH24:MI') as from_time,
           to_char(s.to_time,    'HH24:MI') as to_time,
           case when p_me in (s.author_id, s.taker_id)
                then to_char(s.taker_time, 'HH24:MI') end as taker_time,
           case when p_me in (s.author_id, s.taker_id) then s.taker_note end as taker_note,
           s.offers, s.status,
           case when p_me in (s.author_id, s.taker_id) then s.taker_id end as taker_id,
           case when p_me in (s.author_id, s.taker_id) then t.full_name end as taker_name,
           s.created_at,
           exists (select 1 from public.swap_declines d
                    where d.swap_id = s.id and d.member_id = p_me) as declined_by_me,
           (select count(*) from public.swap_declines d where d.swap_id = s.id) as declines
      from public.swaps s
      join public.members a on a.id = s.author_id
      left join public.members t on t.id = s.taker_id
     where s.status <> 'annullata'
       and (p_from is null or s.target_date >= p_from)
       and (p_to   is null or s.target_date <= p_to)
  ) x
$$;

-- Recupera una richiesta controllando che io possa toccarla
create or replace function public.swap_for_update(p_id uuid, p_me uuid, p_only_parties boolean)
returns public.swaps language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v public.swaps;
begin
  select * into v from public.swaps where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_only_parties and p_me <> v.author_id and p_me is distinct from v.taker_id then
    raise exception 'NOT_YOURS';
  end if;
  return v;
end $$;

-- ------------------------------------------------------------
-- API — accesso
-- ------------------------------------------------------------

-- Elenco nomi per la schermata di accesso (senza token: serve prima di entrare)
create or replace function public.api_people()
returns json language sql stable security definer set search_path = pg_catalog, public, extensions as $$
  select coalesce((
    select json_agg(json_build_object('id', m.id, 'full_name', m.full_name)
                    order by m.full_name)
    from public.members m where m.active
  ), '[]'::json)
$$;

-- Registrazione: nome e cognome + codice di 6 cifre scelto dalla persona
create or replace function public.api_register(p_full_name text, p_pin text)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v_token text; v_first boolean;
begin
  p_full_name := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  p_pin       := btrim(coalesce(p_pin, ''));

  if length(p_full_name) < 3 or p_full_name !~ '\s' then raise exception 'NAME_INVALID'; end if;
  if p_pin !~ '^[0-9]{6}$' then raise exception 'PIN_INVALID'; end if;

  if exists (select 1 from public.members
              where lower(btrim(full_name)) = lower(p_full_name)) then
    raise exception 'NAME_TAKEN';
  end if;

  -- la prima persona che entra tiene le chiavi di casa (solo manutenzione)
  select not exists (select 1 from public.members) into v_first;

  insert into public.members (full_name, pin_hash, role, last_login)
  values (p_full_name, crypt(p_pin, gen_salt('bf', 8)),
          case when v_first then 'admin' else 'member' end, now())
  returning * into v_member;

  v_token := public.new_session(v_member.id);
  return json_build_object('token', v_token, 'member', public.member_json(v_member));
end $$;

-- Accesso: id scelto dalla lista + codice
create or replace function public.api_login(p_id uuid, p_pin text)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v_token text; v_fails int;
begin
  select * into v_member from public.members where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not v_member.active then raise exception 'ACCOUNT_DISABLED'; end if;

  select count(*) into v_fails from public.login_attempts
   where member_id = v_member.id and at > now() - interval '15 minutes';
  if v_fails >= 10 then raise exception 'TOO_MANY_ATTEMPTS'; end if;

  if v_member.pin_hash <> crypt(coalesce(p_pin, ''), v_member.pin_hash) then
    insert into public.login_attempts (member_id) values (v_member.id);
    raise exception 'BAD_PIN';
  end if;

  delete from public.login_attempts where member_id = v_member.id;
  update public.members set last_login = now() where id = v_member.id;

  v_token := public.new_session(v_member.id);
  return json_build_object('token', v_token, 'member', public.member_json(v_member));
end $$;

create or replace function public.api_session(p_token text)
returns json language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  return json_build_object('member', public.member_json(v_member));
end $$;

create or replace function public.api_logout(p_token text)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
begin
  delete from public.sessions
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return json_build_object('ok', true);
end $$;

create or replace function public.api_change_pin(p_token text, p_old text, p_new text)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  if v_member.pin_hash <> crypt(coalesce(p_old, ''), v_member.pin_hash) then
    raise exception 'BAD_PIN';
  end if;
  if coalesce(p_new, '') !~ '^[0-9]{6}$' then raise exception 'PIN_INVALID'; end if;

  update public.members set pin_hash = crypt(p_new, gen_salt('bf', 8))
   where id = v_member.id;
  delete from public.sessions                 -- fuori dagli altri dispositivi
   where member_id = v_member.id
     and token_hash <> encode(digest(p_token, 'sha256'), 'hex');
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- API — richieste di cambio
-- ------------------------------------------------------------

-- Il calendario: tutte le richieste vive nel periodo
create or replace function public.api_month(p_token text, p_from date, p_to date)
returns json language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  return public.swaps_json(v_member.id, p_from, p_to);
end $$;

-- La bacheca: tutto da oggi in poi
create or replace function public.api_board(p_token text)
returns json language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  return public.swaps_json(v_member.id, current_date, null);
end $$;

-- "Il 31 agosto vorrei iniziare alle 9:30"
create or replace function public.api_create(
  p_token text, p_date date, p_kind text default 'orario',
  p_to text default null, p_from text default null,
  p_offers jsonb default '[]'::jsonb)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v_id uuid; v_offers jsonb;
begin
  v_member := public.auth_member(p_token);
  if p_date is null then raise exception 'DATE_REQUIRED'; end if;
  if p_date < current_date then raise exception 'DATE_PAST'; end if;
  if p_kind not in ('orario','off') then raise exception 'KIND_INVALID'; end if;
  -- il giorno off non ha un orario di arrivo: si chiede la giornata intera
  if p_kind = 'orario' and coalesce(p_to, '') = '' then raise exception 'TIME_REQUIRED'; end if;
  if p_kind = 'off' then p_to := null; end if;

  -- i giorni offerti in cambio: solo per il giorno off, solo nella stessa
  -- settimana sabato→venerdì, mai il giorno richiesto, senza doppioni
  if p_kind = 'off' then
    select coalesce(jsonb_agg(jsonb_build_object('d', to_char(d, 'YYYY-MM-DD'),
                                                 't', to_char(t, 'HH24:MI')) order by d), '[]'::jsonb)
      into v_offers
    from (
      select distinct (o->>'d')::date as d, nullif(o->>'t', '')::time as t
        from jsonb_array_elements(coalesce(p_offers, '[]'::jsonb)) o
       where coalesce(o->>'d', '') <> ''
    ) x;

    if exists (select 1 from jsonb_array_elements(v_offers) o
                where (o->>'d')::date = p_date
                   or public.week_start((o->>'d')::date) <> public.week_start(p_date))
    then raise exception 'OFFER_INVALID'; end if;
  else
    v_offers := '[]'::jsonb;
  end if;

  select id into v_id from public.swaps
   where author_id = v_member.id and target_date = p_date
     and status in ('aperta','presa');

  if v_id is null then
    insert into public.swaps (author_id, target_date, kind, to_time, from_time, offers)
    values (v_member.id, p_date, p_kind, nullif(p_to, '')::time, nullif(p_from, '')::time, v_offers)
    returning id into v_id;
  else
    -- modificare la richiesta la rimette in gioco per tutti
    update public.swaps
       set kind = p_kind, to_time = nullif(p_to, '')::time, from_time = nullif(p_from, '')::time,
           offers = v_offers, status = 'aperta', taker_id = null, taker_time = null,
           taken_at = null, resolved_at = null, updated_at = now()
     where id = v_id;
    delete from public.swap_declines where swap_id = v_id;
  end if;

  return json_build_object('ok', true, 'id', v_id);
end $$;

-- "Ci penso io" + comunico il mio orario
create or replace function public.api_take(
  p_token text, p_id uuid, p_my_time text, p_note text default null)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v public.swaps;
begin
  v_member := public.auth_member(p_token);
  v := public.swap_for_update(p_id, v_member.id, false);

  if v.author_id = v_member.id then raise exception 'OWN_REQUEST'; end if;
  if v.status <> 'aperta' then raise exception 'ALREADY_TAKEN'; end if;
  -- per un cambio orario serve sapere a che ora inizi tu; per un giorno off no
  if v.kind = 'orario' and coalesce(p_my_time, '') = '' then raise exception 'TIME_REQUIRED'; end if;

  update public.swaps
     set status = 'presa', taker_id = v_member.id, taker_time = nullif(p_my_time, '')::time,
         taker_note = nullif(btrim(coalesce(p_note, '')), ''),
         taken_at = now(), updated_at = now()
   where id = p_id;
  delete from public.swap_declines where swap_id = p_id and member_id = v_member.id;
  return json_build_object('ok', true);
end $$;

-- "Torna all'inizio": la richiesta torna aperta per tutti
create or replace function public.api_release(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v public.swaps;
begin
  v_member := public.auth_member(p_token);
  v := public.swap_for_update(p_id, v_member.id, true);
  if v.status not in ('presa','risolta') then raise exception 'NOT_TAKEN'; end if;

  update public.swaps
     set status = 'aperta', taker_id = null, taker_time = null, taker_note = null,
         taken_at = null, resolved_at = null, updated_at = now()
   where id = p_id;
  return json_build_object('ok', true);
end $$;

-- "Risolto": il cambio è stato fatto davvero su UKG
create or replace function public.api_resolve(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v public.swaps;
begin
  v_member := public.auth_member(p_token);
  v := public.swap_for_update(p_id, v_member.id, true);
  if v.status <> 'presa' then raise exception 'NOT_TAKEN'; end if;

  update public.swaps set status = 'risolta', resolved_at = now(), updated_at = now()
   where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Riapre una risolta chiusa per sbaglio: torna "presa"
create or replace function public.api_reopen(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v public.swaps;
begin
  v_member := public.auth_member(p_token);
  v := public.swap_for_update(p_id, v_member.id, true);
  if v.status <> 'risolta' then raise exception 'NOT_RESOLVED'; end if;

  update public.swaps set status = 'presa', resolved_at = null, updated_at = now()
   where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.api_cancel(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members; v public.swaps;
begin
  v_member := public.auth_member(p_token);
  v := public.swap_for_update(p_id, v_member.id, true);
  if v.status = 'annullata' then raise exception 'NOT_FOUND'; end if;

  update public.swaps set status = 'annullata', updated_at = now() where id = p_id;
  return json_build_object('ok', true);
end $$;

-- "Non posso" (e ripensamento): segnale facoltativo
create or replace function public.api_decline(p_token text, p_id uuid, p_on boolean default true)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_member public.members;
begin
  v_member := public.auth_member(p_token);
  if p_on then
    insert into public.swap_declines (swap_id, member_id)
    values (p_id, v_member.id) on conflict do nothing;
  else
    delete from public.swap_declines where swap_id = p_id and member_id = v_member.id;
  end if;
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- API — manutenzione del gruppo (non è un ruolo di approvazione:
-- serve solo a reimpostare codici dimenticati e a togliere chi
-- non lavora più qui)
-- ------------------------------------------------------------

create or replace function public.api_members(p_token text)
returns json language plpgsql stable security definer set search_path = pg_catalog, public, extensions as $$
declare v_admin public.members;
begin
  v_admin := public.auth_admin(p_token);
  return coalesce((
    select json_agg(json_build_object(
      'id', m.id, 'full_name', m.full_name, 'role', m.role,
      'active', m.active, 'last_login', m.last_login) order by m.full_name)
    from public.members m
  ), '[]'::json);
end $$;

create or replace function public.api_member_update(
  p_token text, p_id uuid,
  p_role text default null, p_active boolean default null, p_pin text default null)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_admin public.members;
begin
  v_admin := public.auth_admin(p_token);
  if p_id = v_admin.id and (p_role is not null or p_active is not null) then
    raise exception 'CANNOT_EDIT_SELF';
  end if;
  if p_role is not null and p_role not in ('member','admin') then raise exception 'ROLE_INVALID'; end if;
  if p_pin is not null and p_pin !~ '^[0-9]{6}$' then raise exception 'PIN_INVALID'; end if;

  update public.members
     set role     = coalesce(p_role, role),
         active   = coalesce(p_active, active),
         pin_hash = case when p_pin is null then pin_hash
                         else crypt(p_pin, gen_salt('bf', 8)) end
   where id = p_id;

  if p_pin is not null or p_active is false then
    delete from public.sessions       where member_id = p_id;
    delete from public.login_attempts where member_id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.api_member_delete(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path = pg_catalog, public, extensions as $$
declare v_admin public.members;
begin
  v_admin := public.auth_admin(p_token);
  if p_id = v_admin.id then raise exception 'CANNOT_EDIT_SELF'; end if;
  delete from public.members where id = p_id;
  return json_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- Chi può chiamare cosa
-- ------------------------------------------------------------
revoke all on function public.new_session(uuid)                    from public;
revoke all on function public.auth_member(text)                    from public;
revoke all on function public.auth_admin(text)                     from public;
revoke all on function public.member_json(public.members)          from public;
revoke all on function public.swaps_json(uuid,date,date)           from public;
revoke all on function public.swap_for_update(uuid,uuid,boolean)   from public;

grant execute on function
  public.api_people(),
  public.api_register(text,text),
  public.api_login(uuid,text),
  public.api_session(text),
  public.api_logout(text),
  public.api_change_pin(text,text,text),
  public.api_month(text,date,date),
  public.api_board(text),
  public.api_create(text,date,text,text,text,jsonb),
  public.api_take(text,uuid,text,text),
  public.api_release(text,uuid),
  public.api_resolve(text,uuid),
  public.api_reopen(text,uuid),
  public.api_cancel(text,uuid),
  public.api_decline(text,uuid,boolean),
  public.api_members(text),
  public.api_member_update(text,uuid,text,boolean,text),
  public.api_member_delete(text,uuid)
to anon, authenticated;
