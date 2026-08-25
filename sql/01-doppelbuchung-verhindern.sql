-- ============================================================================
--  TCF Padel - Doppelbuchungen strukturell unmoeglich machen
--  Projekt: zqcktdywrajwcfudskxo (Supabase, eu-central-1)
--
--  SCHRITT 0 ZUERST AUSFUEHREN und die Ausgabe pruefen. Schritt 1 erst danach.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- SCHRITT 0 - Diagnose (liest nur, aendert nichts)
-- ----------------------------------------------------------------------------

-- 0a) Welche Constraints/Indizes gibt es auf bookings schon?
select conname, pg_get_constraintdef(oid) as definition
from   pg_constraint
where  conrelid = 'public.bookings'::regclass
order  by conname;

select indexname, indexdef from pg_indexes where tablename = 'bookings';

-- 0b) Wie sichert create_booking heute gegen gleichzeitige Buchungen ab?
--     (Wenn hier ein "select ... for update" oder ein Advisory Lock steht,
--      ist der Constraint unten trotzdem sinnvoll - aber als zweite Schicht,
--      nicht als einzige.)
select pg_get_functiondef('public.create_booking'::regproc);
select pg_get_functiondef('public.cleanup_holds'::regproc);

-- 0c) Welche Status-Werte kommen tatsaechlich vor? Das Constraint-Praedikat
--     unten muss genau die Zustaende abdecken, die einen Platz belegen.
select status, count(*) from bookings group by status order by 2 desc;

-- 0d) Gibt es aktuell schon Ueberschneidungen? Muss leer sein, sonst
--     scheitert Schritt 1 (und dann sind das echte Doppelbuchungen).
select a.booking_nr, b.booking_nr, a.court_id, a.starts_at, b.starts_at
from   bookings a
join   bookings b
  on   a.court_id = b.court_id
 and   a.id < b.id
 and   a.status in ('hold','paid')
 and   b.status in ('hold','paid')
 and   tstzrange(a.starts_at, a.ends_at, '[)') && tstzrange(b.starts_at, b.ends_at, '[)');


-- ----------------------------------------------------------------------------
-- SCHRITT 1 - Der Constraint
--
--  Wirkung: Postgres nimmt zwei sich ueberschneidende Zeitraeume auf demselben
--  Court gar nicht mehr an - unabhaengig davon, was create_booking vorher
--  geprueft hat. Damit ist das Zeitfenster zwischen "ist frei?" und "wird
--  eingetragen" geschlossen, in dem heute zwei gleichzeitige Buchungen
--  durchrutschen koennen.
--
--  Praedikat: nur 'hold' und 'paid' belegen einen Platz. Stornierte und
--  abgelaufene Zeilen sollen denselben Slot wieder freigeben.
--  ACHTUNG: Falls 0c andere Status-Werte zeigt (z. B. 'pending', 'expired'),
--  die Liste hier anpassen, sonst blockiert das Constraint zu viel oder
--  zu wenig.
-- ----------------------------------------------------------------------------

create extension if not exists btree_gist;

alter table public.bookings
  add constraint bookings_kein_doppelter_slot
  exclude using gist (
    court_id  with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  )
  where (status in ('hold','paid'));


-- ----------------------------------------------------------------------------
-- SCHRITT 2 - Nachweis, dass es wirkt (legt zwei Testzeilen an und loescht sie)
--             Der zweite Insert MUSS mit 23P01 exclusion_violation scheitern.
-- ----------------------------------------------------------------------------

do $$
begin
  insert into bookings (court_id, starts_at, ends_at, status, booking_nr)
  values (1, '2099-01-01 10:00+00', '2099-01-01 11:00+00', 'hold', 'TEST-A');

  begin
    insert into bookings (court_id, starts_at, ends_at, status, booking_nr)
    values (1, '2099-01-01 10:30+00', '2099-01-01 11:30+00', 'hold', 'TEST-B');
    raise exception 'FEHLGESCHLAGEN: die Ueberschneidung wurde angenommen';
  exception when exclusion_violation then
    raise notice 'OK - Ueberschneidung wurde abgelehnt';
  end;

  -- direkt anschliessender Slot muss weiterhin gehen ('[)' = Ende exklusiv)
  insert into bookings (court_id, starts_at, ends_at, status, booking_nr)
  values (1, '2099-01-01 11:00+00', '2099-01-01 12:00+00', 'hold', 'TEST-C');
  raise notice 'OK - direkt anschliessende Stunde geht weiterhin';

  delete from bookings where booking_nr in ('TEST-A','TEST-B','TEST-C');
end $$;


-- ----------------------------------------------------------------------------
-- SCHRITT 3 - Was create_booking dann noch braucht
--
--  Mit dem Constraint wirft ein gleichzeitiger zweiter Versuch SQLSTATE 23P01.
--  create_booking muss das abfangen und als "belegt" zurueckgeben, sonst
--  sieht der Kunde einen 500er statt der Meldung "Slot vergeben":
--
--    exception when exclusion_violation then
--      return json_build_object('ok', false, 'reason', 'belegt');
--
--  Ausserdem sollte create_booking abgelaufene Holds fuer den angefragten
--  Slot selbst wegraeumen, bevor es einfuegt - sonst blockiert ein toter Hold
--  den Platz bis zu 5 Minuten, bis cleanup_holds das naechste Mal laeuft:
--
--    delete from bookings
--     where status = 'hold' and hold_expires_at < now()
--       and court_id = p_court_id
--       and tstzrange(starts_at, ends_at, '[)') && tstzrange(p_starts_at, p_ends_at, '[)');
-- ----------------------------------------------------------------------------
