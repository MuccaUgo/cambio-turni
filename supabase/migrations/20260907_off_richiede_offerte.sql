-- Cambio turni — un giorno off deve offrire almeno un giorno in cambio.
--
-- Senza, la richiesta non è uno scambio ma un favore, e chi legge la bacheca
-- non ha modo di valutarla (il semaforo di compatibilità non avrebbe niente
-- da confrontare). L'app disabilita già il pulsante, ma il controllo vero
-- sta qui: /rest/v1/rpc/api_create è chiamabile a mano con la chiave pubblica.
--
-- Sostituisce api_create senza cambiarne la firma, quindi le GRANT restano valide.

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

    -- Un giorno off senza niente in cambio non è uno scambio: è una richiesta
    -- di favore, e chi legge la bacheca non ha modo di valutarla. Almeno un
    -- giorno va offerto. Il controllo sta qui e non solo nell'app, se no
    -- basta chiamare /rest/v1/rpc/api_create a mano per scavalcarlo.
    if jsonb_array_length(v_offers) = 0 then raise exception 'OFFERS_REQUIRED'; end if;
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
