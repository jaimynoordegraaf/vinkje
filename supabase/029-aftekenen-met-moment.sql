-- vinkje — aftekenen met het moment erbij, voor wat op het water gebeurde
--
-- Op het water is er geen bereik. De app bewaart een aftekening daarom lokaal
-- en stuurt hem op zodra er weer verbinding is. Dat kan uren later zijn, en
-- dan is "nu" niet meer het moment waarop het gebeurde.
--
-- Zonder dat onderscheid gaat het mis zodra twee instructeurs dezelfde eis
-- aanraken. Wie het laatst aan land komt wint, ook als hij het eerst aftekende.
-- Dus gaat het moment mee, en geldt: de nieuwste handeling wint, gemeten aan
-- wanneer er getikt werd en niet aan wanneer het aankwam.
--
-- set_sign_off_status blijft zoals hij is. De builds die nu op telefoons staan
-- roepen die aan, en een OTA-update kan vooruitlopen op een migratie.
--
-- Draai na 028-lesmateriaal.sql.

create or replace function set_sign_off_status_at (
  p_enrollment uuid,
  p_requirement uuid,
  p_status sign_off_status,
  p_note text default null,
  p_at timestamptz default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  e enrollments%rowtype;
  moment timestamptz;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then
    raise exception 'Deze opleiding bestaat niet';
  end if;
  if not is_staff(e.group_id) then
    raise exception 'Alleen instructeurs kunnen aftekenen';
  end if;
  if not exists (
    select 1 from requirements r
    where r.id = p_requirement and r.diploma_id = e.diploma_id
  ) then
    raise exception 'Deze eis hoort niet bij dit diploma';
  end if;

  -- De klok van een telefoon kan verkeerd staan. Een moment in de toekomst zou
  -- alles wat erna komt blokkeren -- dat is een aftekening die niemand meer
  -- kan corrigeren -- dus die wordt teruggezet naar nu. Een moment in het
  -- verleden mag wel: dat verliest hooguit van iets nieuwers, en dat klopt.
  moment := least(coalesce(p_at, now()), now());

  if p_status is null then
    -- Weghalen telt ook als handeling: alleen wat ouder is gaat eraan.
    delete from sign_offs
    where enrollment_id = p_enrollment
      and requirement_id = p_requirement
      and signed_at <= moment;
    return;
  end if;

  insert into sign_offs (enrollment_id, requirement_id, diploma_id, signed_by, note, status, signed_at)
  values (
    p_enrollment, p_requirement, e.diploma_id, auth.uid(),
    nullif(trim(coalesce(p_note, '')), ''), p_status, moment
  )
  on conflict (enrollment_id, requirement_id) do update
    set status    = excluded.status,
        signed_by = auth.uid(),
        signed_at = moment,
        note      = case
                      when p_note is null then sign_offs.note
                      else nullif(trim(p_note), '')
                    end
    -- Hier zit de hele regel: een oudere handeling overschrijft geen nieuwere.
    where sign_offs.signed_at <= moment;
end;
$fn$;
