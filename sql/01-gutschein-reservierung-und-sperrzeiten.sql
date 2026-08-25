-- ============================================================================
--  TCF Padel — zwei Luecken in create_booking schliessen
--  Projekt: zqcktdywrajwcfudskxo (Supabase)
--
--  Die Signatur bleibt unveraendert, sonst entsteht eine zweite, ueberladene
--  Funktion und n8n ruft weiter die alte auf.
--
--  (1) Gutschein doppelt einloesbar
--      create_booking rechnet den Gutschein an, mark_booking_paid bucht ihn
--      erst beim Zahlungseingang ab. In den bis zu 15 Minuten dazwischen sieht
--      eine zweite Buchung den vollen Kontostand und rechnet ihn erneut an.
--      Beide werden bezahlt, greatest(0, ...) faengt nur den negativen Stand
--      ab — der Verein verliert den doppelt angerechneten Betrag.
--      Fix: verfuegbar ist der Kontostand MINUS dem, was in noch offenen Holds
--      gebunden ist. Kein Rueckbuchungsmechanismus noetig, weil weiterhin erst
--      bei Zahlung abgebucht wird.
--
--  (2) Sperrzeiten (blackouts) blockieren nichts
--      bookings_no_overlap ist ein EXCLUDE-Constraint auf bookings und kann
--      nur Zeilen derselben Tabelle vergleichen. blackouts wurde nirgends
--      geprueft — die Sperrzeit war reine Anzeige im Raster.
-- ============================================================================

create or replace function public.create_booking(
  p_court_id  smallint,
  p_starts_at timestamp with time zone,
  p_ends_at   timestamp with time zone,
  p_name      text,
  p_email     text,
  p_players   jsonb    default '[]'::jsonb,
  p_members   smallint default 0,
  p_rackets   smallint default 0,
  p_voucher   text     default null::text
) returns jsonb
language plpgsql
security definer
as $function$
declare
  v_hours        int;
  v_price_hour   int;
  v_disc         int;
  v_racket       int;
  v_hold_min     int;
  v_gross        int;
  v_v_balance    int := 0;
  v_v_code       text := null;
  v_v_used       int := 0;
  v_amount       int;
  v_id           uuid;
  v_members      smallint := greatest(0, least(4, coalesce(p_members,0)));
  v_rackets      smallint := greatest(0, least(4, coalesce(p_rackets,0)));
begin
  if p_ends_at <= p_starts_at then
    return jsonb_build_object('ok', false, 'reason', 'Ungültiger Zeitraum.');
  end if;

  -- (2) NEU: Sperrzeit des Vereins geht vor
  if exists (
    select 1 from blackouts
     where court_id = p_court_id
       and tstzrange(starts_at, ends_at, '[)') && tstzrange(p_starts_at, p_ends_at, '[)')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'belegt');
  end if;

  select value::int into v_price_hour from settings where key='price_per_hour_cent';
  select value::int into v_disc       from settings where key='member_discount_cent';
  select value::int into v_racket     from settings where key='racket_price_cent';
  select value::int into v_hold_min   from settings where key='hold_minutes';

  v_hours := greatest(1, round(extract(epoch from (p_ends_at - p_starts_at)) / 3600)::int);
  v_gross := (v_price_hour - v_disc * v_members) * v_hours + v_racket * v_rackets;
  if v_gross < 0 then v_gross := 0; end if;

  -- Gutschein sperren und anrechnen
  if p_voucher is not null and length(trim(p_voucher)) > 0 then
    -- (1) GEAENDERT: was in offenen Holds gebunden ist, gilt als verbraucht
    select v.code,
           v.balance_cent - coalesce((
             select sum(b.voucher_cent)
               from bookings b
              where b.voucher_code = v.code
                and b.status = 'hold'
                and b.hold_expires_at > now()
           ), 0)
      into v_v_code, v_v_balance
      from vouchers v
     where v.code = upper(trim(p_voucher))
       and v.active
       and v.balance_cent > 0
     for update;

    if v_v_code is not null and v_v_balance > 0 then
      v_v_used := least(v_v_balance, v_gross);
    else
      v_v_code := null;          -- vollstaendig reserviert: wie kein Gutschein
    end if;
  end if;

  v_amount := v_gross - v_v_used;

  begin
    insert into bookings (
      court_id, starts_at, ends_at, status, hold_expires_at,
      name, email, players, members, rackets,
      gross_cent, voucher_code, voucher_cent, amount_cent
    ) values (
      p_court_id, p_starts_at, p_ends_at, 'hold', now() + (v_hold_min || ' minutes')::interval,
      p_name, p_email, coalesce(p_players,'[]'::jsonb), v_members, v_rackets,
      v_gross, v_v_code, v_v_used, v_amount
    ) returning id into v_id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'reason', 'belegt');
  end;

  return jsonb_build_object(
    'ok',            true,
    'booking_id',    v_id,
    'gross_cent',    v_gross,
    'voucher_code',  v_v_code,
    'voucher_cent',  v_v_used,
    'amount_cent',   v_amount,
    'amount',        to_char(v_amount / 100.0, 'FM999999990.00')
  );
end;
$function$;


-- ----------------------------------------------------------------------------
-- Nachweis (legt Testdaten an und raeumt sie wieder weg)
-- ----------------------------------------------------------------------------

-- A) Gutschein kann nicht mehr doppelt angerechnet werden
do $$
declare a jsonb; b jsonb; t timestamptz := date_trunc('hour', now()) + interval '30 days';
begin
  insert into vouchers (code, balance_cent, start_cent, active)
  values ('TCF-PRUEF-0001', 2600, 2600, true);

  a := create_booking(1::smallint, t,                    t + interval '1 hour',
                      'Pruef A','a@example.org','[]'::jsonb,0::smallint,0::smallint,'TCF-PRUEF-0001');
  b := create_booking(1::smallint, t + interval '2 hours', t + interval '3 hours',
                      'Pruef B','b@example.org','[]'::jsonb,0::smallint,0::smallint,'TCF-PRUEF-0001');

  raise notice 'A: voucher_cent=%  amount_cent=%', a->>'voucher_cent', a->>'amount_cent';
  raise notice 'B: voucher_cent=%  amount_cent=%', b->>'voucher_cent', b->>'amount_cent';

  if coalesce((b->>'voucher_cent')::int, 0) > 0 then
    raise exception 'FEHLGESCHLAGEN: Gutschein wurde zweimal angerechnet';
  end if;
  raise notice 'OK - die zweite Buchung bekam kein Guthaben mehr';

  delete from bookings where email in ('a@example.org','b@example.org');
  delete from vouchers where code = 'TCF-PRUEF-0001';
end $$;

-- B) Sperrzeit blockiert
do $$
declare r jsonb; t timestamptz := date_trunc('hour', now()) + interval '31 days';
begin
  insert into blackouts (court_id, starts_at, ends_at, reason)
  values (1, t, t + interval '2 hours', 'Pruefung');

  r := create_booking(1::smallint, t, t + interval '1 hour',
                      'Pruef C','c@example.org','[]'::jsonb,0::smallint,0::smallint,null);

  if (r->>'ok')::boolean then
    delete from bookings where email = 'c@example.org';
    raise exception 'FEHLGESCHLAGEN: Buchung ueber die Sperrzeit wurde angenommen';
  end if;
  raise notice 'OK - Sperrzeit blockiert (%)', r->>'reason';

  delete from blackouts where reason = 'Pruefung';
end $$;
