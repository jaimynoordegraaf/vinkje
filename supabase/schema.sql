-- vinkje — het hele schema in één bestand.
--
-- Voor een nieuw Supabase-project: alles in één keer plakken. Draai op een
-- bestaand project de losse genummerde bestanden.
--
-- Let op de volgorde: 010-eisen.sql staat hier achteraan, niet op nummer.
-- De catalogus hangt aan elke schemawijziging die erna genummerd is, dus hij
-- wordt als laatste geladen. Gegenereerd — bewerk de genummerde bestanden.


-- ============================================================ 001-core.sql

-- vinkje — core schema
--
-- Three layers, and they are deliberately separate:
--
--   1. tenancy    groups, speltakken, people, roles — per Scoutinggroep
--   2. catalogue  the Watersport Academy diploma's and their eisen — landelijk,
--                 identical for every groep, and never edited from the app
--   3. progress   who is working towards what, and which eisen are afgetekend
--
-- The catalogue is global on purpose. The eisen are landelijk vastgesteld; if
-- every groep kept its own copy they would drift apart, and an afgetekende eis
-- would stop meaning the same thing. Corrections are made in 010-eisen.sql and
-- re-run — that file upserts on a stable `code`, so ids survive and nothing
-- that was already afgetekend is lost.
--
-- Run this once in the Supabase SQL editor. See supabase/README.md.

-- ---------------------------------------------------------------- types

-- 'instructeur' is this app's leiding: the only role that may aftekenen.
create type member_role as enum ('beheerder', 'instructeur', 'lid');

create type requirement_kind as enum ('praktijk', 'theorie');

-- ---------------------------------------------------------------- tenancy

create table groups (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  slug         text not null unique,
  accent_color text not null default '#14445F',
  created_at   timestamptz not null default now()
);

-- speltakken: Zeeverkenners, Wilde Vaart, Loodsen, Stam, ...
create table sections (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups (id) on delete cascade,
  name       text not null,
  color      text,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (group_id, name)
);

-- one row per signed-in person, 1:1 with auth.users
create table profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table memberships (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups (id) on delete cascade,
  profile_id uuid not null references profiles (id) on delete cascade,
  role       member_role not null default 'lid',
  created_at timestamptz not null default now(),
  unique (group_id, profile_id)
);

create index on memberships (profile_id);
create index on memberships (group_id);

create table membership_sections (
  membership_id uuid not null references memberships (id) on delete cascade,
  section_id    uuid not null references sections (id) on delete cascade,
  primary key (membership_id, section_id)
);

create index on membership_sections (section_id);

-- invite codes; the only way into a groep
create table invites (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups (id) on delete cascade,
  code       text not null unique,
  role       member_role not null default 'lid',
  section_id uuid references sections (id) on delete set null,
  label      text,
  expires_at timestamptz,
  max_uses   int not null default 1,
  uses       int not null default 0,
  created_by uuid references profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- catalogue

-- Roeien, Zeilen (kielboot), Buitenboordmotor, Sloep/Motorvlet.
create table disciplines (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  subtitle   text,
  sort_order int not null default 0
);

create table diplomas (
  id            uuid primary key default gen_random_uuid(),
  discipline_id uuid not null references disciplines (id) on delete cascade,
  code          text not null unique,
  name          text not null,
  -- "I/II", "III" — the level as it is printed on the diploma
  level_label   text,
  -- the one-paragraph description of what the holder is trusted to do
  summary       text,
  -- how long a passed theorie-examen stays valid; 18 months landelijk
  theory_valid_months int not null default 18,
  source        text,
  sort_order    int not null default 0,
  -- the other half of the composite key that sign_offs points at
  unique (id, discipline_id)
);

create index on diplomas (discipline_id);

create table requirements (
  id         uuid primary key default gen_random_uuid(),
  diploma_id uuid not null references diplomas (id) on delete cascade,
  code       text not null unique,
  kind       requirement_kind not null,
  -- the number it carries in the handboek, so instructeur and boekje match
  position   int not null,
  title      text not null,
  -- the "toelichting op de eisen" where the handboek gives one
  detail     text,
  unique (diploma_id, kind, position),
  unique (id, diploma_id)
);

create index on requirements (diploma_id);

-- ---------------------------------------------------------------- progress

-- One member working towards one diploma.
create table enrollments (
  id               uuid primary key default gen_random_uuid(),
  group_id         uuid not null references groups (id) on delete cascade,
  profile_id       uuid not null references profiles (id) on delete cascade,
  diploma_id       uuid not null references diplomas (id) on delete restrict,
  started_on       date not null default current_date,
  -- the landelijke theorie-examen; the praktijkexamen needs a valid one
  theory_passed_on date,
  -- set when the diploma itself has been handed out
  awarded_on       date,
  note             text,
  created_by       uuid references profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  unique (group_id, profile_id, diploma_id),
  unique (id, diploma_id)
);

create index on enrollments (group_id);
create index on enrollments (profile_id);

-- One eis, afgetekend. The row existing is the aftekening; removing it undoes
-- it. `signed_by` is never the candidate: only instructeurs may write here,
-- and the policy pins it to auth.uid(), so the name on an aftekening is always
-- the person who was actually there.
create table sign_offs (
  id             uuid primary key default gen_random_uuid(),
  enrollment_id  uuid not null,
  requirement_id uuid not null,
  -- carried so the database itself can refuse an eis from another diploma
  diploma_id     uuid not null,
  signed_by      uuid references profiles (id) on delete set null,
  signed_at      timestamptz not null default now(),
  note           text,
  unique (enrollment_id, requirement_id),
  foreign key (enrollment_id, diploma_id)
    references enrollments (id, diploma_id) on delete cascade,
  foreign key (requirement_id, diploma_id)
    references requirements (id, diploma_id) on delete cascade
);

create index on sign_offs (enrollment_id);

-- ---------------------------------------------------------------- helpers
-- security definer, so policies that consult membership do not recurse into
-- the policies on memberships itself.

create or replace function is_member (gid uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships m
    where m.group_id = gid and m.profile_id = auth.uid()
  );
$fn$;

-- Instructeurs and beheerders: the people who may aftekenen and who see
-- everyone's voortgang.
create or replace function is_staff (gid uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships m
    where m.group_id = gid and m.profile_id = auth.uid()
      and m.role in ('beheerder', 'instructeur')
  );
$fn$;

create or replace function is_admin (gid uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships m
    where m.group_id = gid and m.profile_id = auth.uid() and m.role = 'beheerder'
  );
$fn$;

create or replace function shares_group (pid uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships a
    join memberships b on b.group_id = a.group_id
    where a.profile_id = auth.uid() and b.profile_id = pid
  );
$fn$;

create or replace function is_staff_over (pid uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships a
    join memberships b on b.group_id = a.group_id
    where a.profile_id = auth.uid()
      and a.role in ('beheerder', 'instructeur')
      and b.profile_id = pid
  );
$fn$;

create or replace function membership_group (mid uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from memberships where id = mid;
$fn$;

-- the groep and the candidate behind an enrollment, without tripping its policy
create or replace function enrollment_group (eid uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from enrollments where id = eid;
$fn$;

create or replace function enrollment_profile (eid uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select profile_id from enrollments where id = eid;
$fn$;

-- ---------------------------------------------------------------- counts
--
-- security_invoker: the view is read with the caller's own rights, so the
-- policies on enrollments and sign_offs still apply. Without it a view owned
-- by postgres would hand every groep's voortgang to anyone who asked.

create view enrollment_progress
  with (security_invoker = true) as
  select
    e.id                                           as enrollment_id,
    count(r.id) filter (where r.kind = 'praktijk') as praktijk_total,
    count(s.id) filter (where r.kind = 'praktijk') as praktijk_done,
    count(r.id) filter (where r.kind = 'theorie')  as theorie_total,
    count(s.id) filter (where r.kind = 'theorie')  as theorie_done,
    count(r.id)                                    as total,
    count(s.id)                                    as done
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id
  left join sign_offs s
    on s.enrollment_id = e.id and s.requirement_id = r.id
  group by e.id;

-- ---------------------------------------------------------------- bootstrap
-- A profile row is created for every new auth user, so the app never has to
-- guess whether one exists.

create or replace function handle_new_user ()
  returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  insert into profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$fn$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user ();

-- ============================================================ 002-rls.sql

-- vinkje — row level security
--
-- Two rules run through all of it:
--
--   * You only ever reach a groep you are a member of.
--   * Aftekenen is an instructeur's act. A kandidaat can read their own
--     voortgang and nothing else about it — they cannot add an eis to their
--     own lijst, cannot tick one off, and cannot untick one.
--
-- The catalogue is the exception: every signed-in person may read the eisen of
-- every diploma, because that is what makes the app useful to a lid who wants
-- to know what is still coming. Nobody may write to it through the API at all
-- — it is maintained by running 010-eisen.sql in the SQL editor.
--
-- Run after 001-core.sql.

-- ---------------------------------------------------------------- enable RLS

alter table groups              enable row level security;
alter table sections            enable row level security;
alter table profiles            enable row level security;
alter table memberships         enable row level security;
alter table membership_sections enable row level security;
alter table invites             enable row level security;
alter table disciplines         enable row level security;
alter table diplomas            enable row level security;
alter table requirements        enable row level security;
alter table enrollments         enable row level security;
alter table sign_offs           enable row level security;

-- ---------------------------------------------------------------- groups

create policy groups_read on groups
  for select to authenticated using (is_member(id));

create policy groups_admin_update on groups
  for update to authenticated using (is_admin(id)) with check (is_admin(id));

-- ---------------------------------------------------------------- sections

create policy sections_read on sections
  for select to authenticated using (is_member(group_id));

create policy sections_admin_write on sections
  for all to authenticated using (is_admin(group_id)) with check (is_admin(group_id));

-- ---------------------------------------------------------------- profiles

-- Your own row, and the rows of people in your groep. A lid needs the second
-- half: an aftekening carries the name of the instructeur who gave it, and a
-- name it cannot read would show up as an empty line.
create policy profiles_read on profiles
  for select to authenticated using (id = auth.uid() or shares_group(id));

create policy profiles_insert_self on profiles
  for insert to authenticated with check (id = auth.uid());

create policy profiles_update_self on profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------- memberships

create policy memberships_read on memberships
  for select to authenticated using (is_member(group_id));

create policy memberships_admin_write on memberships
  for all to authenticated using (is_admin(group_id)) with check (is_admin(group_id));

create policy membership_sections_read on membership_sections
  for select to authenticated using (is_member(membership_group(membership_id)));

create policy membership_sections_admin_write on membership_sections
  for all to authenticated
  using (is_admin(membership_group(membership_id)))
  with check (is_admin(membership_group(membership_id)));

-- ---------------------------------------------------------------- invites

create policy invites_staff_read on invites
  for select to authenticated using (is_staff(group_id));

create policy invites_admin_write on invites
  for all to authenticated using (is_admin(group_id)) with check (is_admin(group_id));

-- ---------------------------------------------------------------- catalogue
--
-- Read-only, for everyone who is signed in. There is deliberately no insert,
-- update or delete policy: with RLS on and no write policy, the API refuses
-- every write, whoever asks.

create policy disciplines_read on disciplines
  for select to authenticated using (true);

create policy diplomas_read on diplomas
  for select to authenticated using (true);

create policy requirements_read on requirements
  for select to authenticated using (true);

-- ---------------------------------------------------------------- enrollments

-- Instructeurs see everyone in their groep; a lid sees only their own.
create policy enrollments_read on enrollments
  for select to authenticated
  using (is_staff(group_id) or profile_id = auth.uid());

create policy enrollments_staff_write on enrollments
  for all to authenticated
  using (is_staff(group_id))
  with check (is_staff(group_id));

-- ---------------------------------------------------------------- sign_offs

create policy sign_offs_read on sign_offs
  for select to authenticated
  using (
    is_staff(enrollment_group(enrollment_id))
    or enrollment_profile(enrollment_id) = auth.uid()
  );

-- `signed_by = auth.uid()` is the whole point: an instructeur can aftekenen,
-- but not in someone else's name.
create policy sign_offs_staff_insert on sign_offs
  for insert to authenticated
  with check (
    is_staff(enrollment_group(enrollment_id))
    and signed_by = auth.uid()
  );

create policy sign_offs_staff_update on sign_offs
  for update to authenticated
  using (is_staff(enrollment_group(enrollment_id)))
  with check (
    is_staff(enrollment_group(enrollment_id))
    and signed_by = auth.uid()
  );

create policy sign_offs_staff_delete on sign_offs
  for delete to authenticated
  using (is_staff(enrollment_group(enrollment_id)));

-- ============================================================ 003-rpc.sql

-- vinkje — the calls the app makes that policies alone cannot express
--
-- Every function here is `security definer`, which means it runs with the
-- rights of its owner and RLS does not apply inside it. So each one checks
-- `auth.uid()` itself, at the top. Those checks are the only thing between a
-- caller and another groep's data — do not remove one to "simplify".
--
-- Run after 002-rls.sql.

-- ---------------------------------------------------------------- create a groep

create or replace function create_group (p_name text, p_slug text)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  gid uuid;
begin
  if auth.uid() is null then
    raise exception 'niet ingelogd';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'naam is verplicht';
  end if;

  insert into groups (name, slug)
  values (trim(p_name), lower(trim(p_slug)))
  returning id into gid;

  insert into memberships (group_id, profile_id, role)
  values (gid, auth.uid(), 'beheerder');

  return gid;
end;
$fn$;

-- ---------------------------------------------------------------- join a groep
-- The member never reads the invites table; they hand over a code and this
-- decides. Returns the groep they are now in.

create or replace function redeem_invite (p_code text)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  inv invites%rowtype;
  mid uuid;
  -- A use is only spent when the code actually did something. Someone already
  -- in the groep entering it again is harmless and must not burn the code a
  -- new member is waiting for.
  changed boolean := false;
begin
  if auth.uid() is null then
    raise exception 'niet ingelogd';
  end if;

  select * into inv from invites
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'Deze code kennen we niet';
  end if;
  if inv.expires_at is not null and inv.expires_at < now() then
    raise exception 'Deze code is verlopen';
  end if;
  if inv.uses >= inv.max_uses then
    raise exception 'Deze code is al gebruikt';
  end if;

  select id into mid from memberships
  where group_id = inv.group_id and profile_id = auth.uid();

  if mid is null then
    insert into memberships (group_id, profile_id, role)
    values (inv.group_id, auth.uid(), inv.role)
    returning id into mid;
    changed := true;
  end if;

  if inv.section_id is not null then
    insert into membership_sections (membership_id, section_id)
    values (mid, inv.section_id)
    on conflict do nothing;
    if found then changed := true; end if;
  end if;

  if changed then
    update invites set uses = uses + 1 where id = inv.id;
  end if;

  return inv.group_id;
end;
$fn$;

-- ---------------------------------------------------------------- de vaarders
-- The ledenlijst an instructeur opens: everyone in the groep, with how many
-- diploma's they are working on and how many they already have. Staff only —
-- a lid has no business with a list of everyone else's voortgang.

create or replace function group_members (p_group uuid)
  returns table (
    profile_id uuid,
    full_name  text,
    role       member_role,
    sections   text[],
    in_progress bigint,
    awarded     bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    p.id,
    p.full_name,
    m.role,
    coalesce(
      (select array_agg(s.name order by s.sort_order, s.name)
       from membership_sections ms
       join sections s on s.id = ms.section_id
       where ms.membership_id = m.id),
      '{}'
    ),
    (select count(*) from enrollments e
     where e.group_id = p_group and e.profile_id = p.id and e.awarded_on is null),
    (select count(*) from enrollments e
     where e.group_id = p_group and e.profile_id = p.id and e.awarded_on is not null)
  from memberships m
  join profiles p on p.id = m.profile_id
  where m.group_id = p_group
    and is_staff(p_group)
  order by p.full_name;
$fn$;

-- ---------------------------------------------------------------- voortgang
-- The diploma's one person is working towards, with the counts that drive the
-- progress bars. Pass p_profile to look at one member; leave it null for the
-- caller's own. A lid can only ever get their own rows back.

create or replace function member_enrollments (p_group uuid, p_profile uuid default null)
  returns table (
    enrollment_id    uuid,
    profile_id       uuid,
    full_name        text,
    diploma_id       uuid,
    diploma_code     text,
    diploma_name     text,
    level_label      text,
    discipline_code  text,
    discipline_name  text,
    theory_valid_months int,
    started_on       date,
    theory_passed_on date,
    awarded_on       date,
    note             text,
    praktijk_total   bigint,
    praktijk_done    bigint,
    theorie_total    bigint,
    theorie_done     bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    e.id, e.profile_id, p.full_name,
    d.id, d.code, d.name, d.level_label,
    disc.code, disc.name, d.theory_valid_months,
    e.started_on, e.theory_passed_on, e.awarded_on, e.note,
    count(r.id) filter (where r.kind = 'praktijk'),
    count(s.id) filter (where r.kind = 'praktijk'),
    count(r.id) filter (where r.kind = 'theorie'),
    count(s.id) filter (where r.kind = 'theorie')
  from enrollments e
  join profiles p on p.id = e.profile_id
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  join requirements r on r.diploma_id = d.id
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
    and e.profile_id = coalesce(p_profile, auth.uid())
    -- the guard: staff may look at anyone in their groep, everyone else only
    -- at themselves
    and (is_staff(p_group) or coalesce(p_profile, auth.uid()) = auth.uid())
    and is_member(p_group)
  -- the primary keys are enough: everything else selected from those tables is
  -- functionally dependent on them
  group by e.id, p.full_name, d.id, disc.id
  order by e.awarded_on nulls first, disc.sort_order, d.sort_order;
$fn$;

-- ---------------------------------------------------------------- de aftekenlijst
-- One enrollment, every eis, and who signed it off when. This is the screen
-- the app spends most of its time on, so it is one round trip.

create or replace function enrollment_sheet (p_enrollment uuid)
  returns table (
    requirement_id uuid,
    kind           requirement_kind,
    -- quoted: `position` is a keyword, and a returns-table column called that
    -- is a syntax error where a table column of the same name is fine
    "position"     int,
    title          text,
    detail         text,
    signed_at      timestamptz,
    signed_by      uuid,
    signed_by_name text,
    note           text
  )
  language sql stable security definer set search_path = public as $fn$
  select
    r.id, r.kind, r.position, r.title, r.detail,
    s.signed_at, s.signed_by, sp.full_name, s.note
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  left join profiles sp on sp.id = s.signed_by
  where e.id = p_enrollment
    and (is_staff(e.group_id) or e.profile_id = auth.uid())
  order by r.kind, r.position;
$fn$;

-- ---------------------------------------------------------------- aftekenen
-- Toggling one eis. Doing it here rather than from the app means the
-- enrollment's diploma_id is filled in by the database, so a sign_off can
-- never point at an eis from another diploma, and `signed_by` is never
-- anything but the caller.

create or replace function set_sign_off (
  p_enrollment uuid,
  p_requirement uuid,
  p_signed boolean,
  p_note text default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  e enrollments%rowtype;
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

  if p_signed then
    insert into sign_offs (enrollment_id, requirement_id, diploma_id, signed_by, note)
    values (p_enrollment, p_requirement, e.diploma_id, auth.uid(), nullif(trim(coalesce(p_note, '')), ''))
    on conflict (enrollment_id, requirement_id) do update
      set signed_by = auth.uid(),
          signed_at = now(),
          note      = excluded.note;
  else
    delete from sign_offs
    where enrollment_id = p_enrollment and requirement_id = p_requirement;
  end if;
end;
$fn$;

-- ============================================================ 011-laatste-beheerder.sql

-- vinkje — een groep raakt zijn laatste beheerder niet kwijt
--
-- Het rollenscherm liet een beheerder zichzelf met één tik lid maken. Daarna
-- kan diezelfde persoon niets meer beheren — ook niet zijn eigen rol
-- terugzetten — en is er niemand anders die het kan. De enige uitweg is de SQL
-- Editor, en dat is geen uitweg voor een leidinggevende op een vaaravond.
--
-- Een waarschuwing in de app was er al en hielp niet, want de tik is precies
-- even makkelijk met of zonder waarschuwing. Dus staat de regel hier: wie de
-- laatste beheerder van een groep is, kan die rol niet verliezen.
--
-- Alleen bij UPDATE, met opzet. Bij DELETE zou dezelfde controle het
-- verwijderen van een groep blokkeren (memberships hangt er met cascade aan) en
-- het opheffen van een account (profiles idem). Een beheerder die zijn eigen
-- lidmaatschap weggooit is een bewuste daad die de app nergens aanbiedt; een
-- account dat niet meer opgeheven kan worden is een echt probleem.
--
-- Draai na 010-eisen.sql.

create or replace function keep_one_beheerder ()
  returns trigger language plpgsql set search_path = public as $fn$
begin
  -- Alleen het wegnemen van een beheerdersrol is interessant.
  if old.role <> 'beheerder' then
    return new;
  end if;
  if new.role = 'beheerder' and new.group_id = old.group_id then
    return new;
  end if;

  if not exists (
    select 1 from memberships
    where group_id = old.group_id
      and role = 'beheerder'
      and id <> old.id
  ) then
    raise exception
      'Dit is de laatste beheerder van de groep. Maak eerst iemand anders beheerder.';
  end if;

  return new;
end;
$fn$;

drop trigger if exists memberships_keep_one_beheerder on memberships;

create trigger memberships_keep_one_beheerder
  before update on memberships
  for each row execute function keep_one_beheerder ();

-- ============================================================ 012-onderdelen.sql

-- vinkje — losse onderdelen binnen één eis
--
-- "Schiemanswerk" is één regel op de vorderingenstaat, maar er zitten zes
-- knopen achter. Met één vinkje is niet bij te houden wie de paalsteek al kan
-- en de mastworp nog niet, en dat is precies wat een instructeur tussen twee
-- vaaravonden door kwijtraakt.
--
-- Een onderdeel is daarom gewoon een eis met een ouder. Dat betekent dat
-- sign_offs, de policies en set_sign_off er niets van hoeven te weten: een
-- onderdeel wordt afgetekend zoals alles hier wordt afgetekend, met een datum
-- en een naam.
--
-- Wat een onderdeel níét doet, is de eis afstrepen. Alle zes de knopen gelegd
-- is niet hetzelfde als "beheerst schiemanswerk"; die beoordeling blijft van de
-- instructeur. Daarom tellen alleen eisen zonder ouder mee in de voortgang —
-- het aantal eisen van een diploma blijft staan op wat het handboek zegt.
--
-- Draai na 011-laatste-beheerder.sql, en draai daarna 010-eisen.sql opnieuw om
-- de onderdelen te laden.

alter table requirements add column if not exists parent_id uuid;

-- De samengestelde sleutel doet hier twee dingen tegelijk: hij wijst de ouder
-- aan én dwingt af dat die bij hetzelfde diploma hoort. Een onderdeel van
-- Kielboot I kan zo nooit onder een eis van Roeien III hangen.
alter table requirements drop constraint if exists requirements_parent_same_diploma;
alter table requirements
  add constraint requirements_parent_same_diploma
  foreign key (parent_id, diploma_id)
  references requirements (id, diploma_id) on delete cascade;

create index if not exists requirements_parent_id_idx on requirements (parent_id);

-- De oude unieke sleutel ging uit van één laag. Nu tellen eisen door binnen hun
-- diploma, en onderdelen binnen hun eis.
alter table requirements drop constraint if exists requirements_diploma_id_kind_position_key;

drop index if exists requirements_top_position;
drop index if exists requirements_sub_position;

create unique index requirements_top_position
  on requirements (diploma_id, kind, position) where parent_id is null;

create unique index requirements_sub_position
  on requirements (parent_id, position) where parent_id is not null;

-- Eén laag diep. Een onderdeel van een onderdeel is geen vorderingenstaat meer
-- maar een boomstructuur, en daar is geen enkel scherm op gebouwd.
create or replace function requirements_one_level ()
  returns trigger language plpgsql set search_path = public as $fn$
begin
  if new.parent_id is not null and exists (
    select 1 from requirements p
    where p.id = new.parent_id and p.parent_id is not null
  ) then
    raise exception 'Een onderdeel kan zelf geen onderdelen hebben';
  end if;
  return new;
end;
$fn$;

drop trigger if exists requirements_one_level on requirements;

create trigger requirements_one_level
  before insert or update on requirements
  for each row execute function requirements_one_level ();

-- ---------------------------------------------------------------- tellen
--
-- Overal waar voortgang geteld wordt, tellen alleen de eisen zelf mee.

create or replace view enrollment_progress
  with (security_invoker = true) as
  select
    e.id                                           as enrollment_id,
    count(r.id) filter (where r.kind = 'praktijk') as praktijk_total,
    count(s.id) filter (where r.kind = 'praktijk') as praktijk_done,
    count(r.id) filter (where r.kind = 'theorie')  as theorie_total,
    count(s.id) filter (where r.kind = 'theorie')  as theorie_done,
    count(r.id)                                    as total,
    count(s.id)                                    as done
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id and r.parent_id is null
  left join sign_offs s
    on s.enrollment_id = e.id and s.requirement_id = r.id
  group by e.id;

create or replace function member_enrollments (p_group uuid, p_profile uuid default null)
  returns table (
    enrollment_id    uuid,
    profile_id       uuid,
    full_name        text,
    diploma_id       uuid,
    diploma_code     text,
    diploma_name     text,
    level_label      text,
    discipline_code  text,
    discipline_name  text,
    theory_valid_months int,
    started_on       date,
    theory_passed_on date,
    awarded_on       date,
    note             text,
    praktijk_total   bigint,
    praktijk_done    bigint,
    theorie_total    bigint,
    theorie_done     bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    e.id, e.profile_id, p.full_name,
    d.id, d.code, d.name, d.level_label,
    disc.code, disc.name, d.theory_valid_months,
    e.started_on, e.theory_passed_on, e.awarded_on, e.note,
    count(r.id) filter (where r.kind = 'praktijk'),
    count(s.id) filter (where r.kind = 'praktijk'),
    count(r.id) filter (where r.kind = 'theorie'),
    count(s.id) filter (where r.kind = 'theorie')
  from enrollments e
  join profiles p on p.id = e.profile_id
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  join requirements r on r.diploma_id = d.id and r.parent_id is null
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
    and e.profile_id = coalesce(p_profile, auth.uid())
    and (is_staff(p_group) or coalesce(p_profile, auth.uid()) = auth.uid())
    and is_member(p_group)
  group by e.id, p.full_name, d.id, disc.id
  order by e.awarded_on nulls first, disc.sort_order, d.sort_order;
$fn$;

-- ---------------------------------------------------------------- de lijst
--
-- De aftekenlijst geeft eisen én onderdelen terug; het scherm nestelt ze op
-- parent_id. Onderdelen komen achter hun eigen eis te staan, zodat de app ze
-- in volgorde kan doorlopen zonder te sorteren.

drop function if exists enrollment_sheet (uuid);

create or replace function enrollment_sheet (p_enrollment uuid)
  returns table (
    requirement_id uuid,
    parent_id      uuid,
    kind           requirement_kind,
    "position"     int,
    title          text,
    detail         text,
    signed_at      timestamptz,
    signed_by      uuid,
    signed_by_name text,
    note           text
  )
  language sql stable security definer set search_path = public as $fn$
  select
    r.id, r.parent_id, r.kind, r.position, r.title, r.detail,
    s.signed_at, s.signed_by, sp.full_name, s.note
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  left join profiles sp on sp.id = s.signed_by
  where e.id = p_enrollment
    and (is_staff(e.group_id) or e.profile_id = auth.uid())
  order by
    r.kind,
    coalesce((select p.position from requirements p where p.id = r.parent_id), r.position),
    r.parent_id nulls first,
    r.position;
$fn$;

-- ============================================================ 013-beheer.sql

-- vinkje — iemand uit de groep halen, en de catalogus bewerkbaar maken
--
-- Twee dingen die tot nu toe alleen via de SQL Editor konden.
--
-- 1. Iemand verwijderen. De aftekeningen blijven staan: als een lid volgend
--    seizoen terugkomt met een nieuwe code, staat zijn vorderingenstaat er weer
--    precies zoals hij hem achterliet. Wie weg is uit de groep ziet en telt
--    nergens mee, maar wat hij heeft laten zien is niet ongedaan gemaakt door
--    het verlopen van een lidmaatschap.
--
-- 2. De catalogus. Die was met opzet vanuit de app niet te wijzigen, met de
--    redenering dat de eisen landelijk vastgesteld zijn. Dat blijft waar, maar
--    de werkelijkheid duwt terug: de sloep/motorvlet-lijst moet per niveau
--    nagelopen worden, en dat kan niet elke keer een SQL-plakoefening zijn.
--    Beheerders mogen hem nu bewerken vanuit de beheerpagina.
--
--    Let op wat dat betekent: de catalogus is gedeeld. Een wijziging geldt voor
--    elke groep in deze database. Zolang dat er één is, is dat geen probleem —
--    komt er een tweede groep bij, dan moet dit opnieuw bekeken worden.
--
-- Draai na 012-onderdelen.sql.

-- ---------------------------------------------------------------- verwijderen
--
-- Verwijderen gaat via deze functie en niet via een delete-policy, zodat de
-- controle op de laatste beheerder er niet omheen kan. De trigger uit
-- 011 dekt alleen UPDATE — bij DELETE zou die het opheffen van een groep of
-- een account blokkeren, dus zit de regel hier nog een keer.

create or replace function remove_member (p_group uuid, p_profile uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  target member_role;
begin
  if not is_admin(p_group) then
    raise exception 'Alleen een beheerder kan iemand uit de groep halen';
  end if;

  select role into target from memberships
  where group_id = p_group and profile_id = p_profile;

  if not found then
    raise exception 'Deze persoon zit niet in de groep';
  end if;

  if target = 'beheerder' and not exists (
    select 1 from memberships
    where group_id = p_group and role = 'beheerder' and profile_id <> p_profile
  ) then
    raise exception
      'Dit is de laatste beheerder van de groep. Maak eerst iemand anders beheerder.';
  end if;

  delete from memberships where group_id = p_group and profile_id = p_profile;
end;
$fn$;

-- De brede for-all-policy gaf ook delete weg. Die wordt gesplitst, zodat
-- remove_member de enige weg naar buiten is. Cascades vanuit groups en
-- profiles blijven werken: die voert de database zelf uit, buiten de policies om.
drop policy if exists memberships_admin_write on memberships;

create policy memberships_admin_insert on memberships
  for insert to authenticated with check (is_admin(group_id));

create policy memberships_admin_update on memberships
  for update to authenticated
  using (is_admin(group_id)) with check (is_admin(group_id));

-- ---------------------------------------------------------------- catalogus

create or replace function is_any_admin ()
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships
    where profile_id = auth.uid() and role = 'beheerder'
  );
$fn$;

create policy disciplines_admin_write on disciplines
  for all to authenticated using (is_any_admin()) with check (is_any_admin());

create policy diplomas_admin_write on diplomas
  for all to authenticated using (is_any_admin()) with check (is_any_admin());

create policy requirements_admin_write on requirements
  for all to authenticated using (is_any_admin()) with check (is_any_admin());

-- ---------------------------------------------------------------- wat er hangt
--
-- Voor de beheerpagina: hoeveel er aan een diploma of een eis vastzit, zodat
-- een beheerder wéét wat hij weggooit voordat hij het weggooit.

create or replace function catalogue_usage ()
  returns table (
    diploma_id     uuid,
    enrollments    bigint,
    sign_offs      bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    d.id,
    count(distinct e.id),
    count(s.id)
  from diplomas d
  left join enrollments e on e.diploma_id = d.id
  left join sign_offs s on s.enrollment_id = e.id
  where is_any_admin()
  group by d.id;
$fn$;

-- ============================================================ 014-speltakken.sql

-- vinkje — speltakken die ook echt ergens aan hangen
--
-- De tabellen stonden er vanaf het begin, meegekomen uit het fundament van de
-- groepsapp, maar er was geen enkele manier om iemand in een speltak te zetten.
-- De enige schrijver was redeem_invite, en het scherm waar je codes maakt liet
-- je geen speltak kiezen — dus bleef membership_sections leeg en verschenen de
-- labels op de ledenlijst nooit.
--
-- Dit bestand maakt het af: de ledenlijst geeft de speltakken nu ook als ids
-- terug zodat er op gefilterd kan worden, en toewijzen gaat via één functie die
-- de hele set in één keer vervangt.
--
-- Draai na 013-beheer.sql.

-- ---------------------------------------------------------------- ledenlijst
--
-- Namen erbij voor het scherm, ids erbij voor het filter en de toewijzing, en
-- membership_id omdat membership_sections daarop hangt en niet op profile_id.

drop function if exists group_members (uuid);

create or replace function group_members (p_group uuid)
  returns table (
    profile_id    uuid,
    membership_id uuid,
    full_name     text,
    role          member_role,
    sections      text[],
    section_ids   uuid[],
    in_progress   bigint,
    awarded       bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    p.id,
    m.id,
    p.full_name,
    m.role,
    coalesce(
      (select array_agg(s.name order by s.sort_order, s.name)
       from membership_sections ms
       join sections s on s.id = ms.section_id
       where ms.membership_id = m.id),
      '{}'
    ),
    coalesce(
      (select array_agg(s.id order by s.sort_order, s.name)
       from membership_sections ms
       join sections s on s.id = ms.section_id
       where ms.membership_id = m.id),
      '{}'
    ),
    (select count(*) from enrollments e
     where e.group_id = p_group and e.profile_id = p.id and e.awarded_on is null),
    (select count(*) from enrollments e
     where e.group_id = p_group and e.profile_id = p.id and e.awarded_on is not null)
  from memberships m
  join profiles p on p.id = m.profile_id
  where m.group_id = p_group
    and is_staff(p_group)
  order by p.full_name;
$fn$;

-- ---------------------------------------------------------------- toewijzen
--
-- De hele set in één keer vervangen in plaats van los toevoegen en weghalen.
-- Een scherm met vinkjes weet welke speltakken aan horen te staan; het zou de
-- verschillen zelf moeten uitrekenen, en dan halverwege kunnen stranden met een
-- lid dat in twee speltakken tegelijk zit die elkaar uitsluiten.

create or replace function set_member_sections (
  p_group uuid,
  p_profile uuid,
  p_sections uuid[]
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  mid uuid;
begin
  if not is_admin(p_group) then
    raise exception 'Alleen een beheerder kan speltakken toewijzen';
  end if;

  select id into mid from memberships
  where group_id = p_group and profile_id = p_profile;

  if not found then
    raise exception 'Deze persoon zit niet in de groep';
  end if;

  -- Een speltak van een andere groep zou hier binnen kunnen komen omdat de
  -- functie security definer is en de policies dus niet meekijken.
  if exists (
    select 1
    from unnest(coalesce(p_sections, '{}'::uuid[])) as given(id)
    where not exists (
      select 1 from sections s where s.id = given.id and s.group_id = p_group
    )
  ) then
    raise exception 'Die speltak hoort niet bij deze groep';
  end if;

  delete from membership_sections where membership_id = mid;

  insert into membership_sections (membership_id, section_id)
  select mid, given.id
  from unnest(coalesce(p_sections, '{}'::uuid[])) as given(id);
end;
$fn$;

-- ============================================================ 015-leden-zonder-account.sql

-- vinkje — leden die geen account hebben
--
-- Tot nu toe was een lid hetzelfde als een account: profiles.id verwees naar
-- auth.users, dus je kon alleen in het register staan als je je had aangemeld.
-- Dat past niet bij de werkelijkheid. De meeste vaarders zijn kinderen zonder
-- telefoon; die gaan zich niet aanmelden, en hun vorderingenstaat moet er toch
-- zijn.
--
-- Dus knipt dit bestand die twee uit elkaar. Een profiel is voortaan "een
-- persoon in het register". Heeft iemand een account, dan is zijn profiel-id
-- gelijk aan zijn auth-id — precies zoals het altijd al was, en daarom blijft
-- elke policy die `= auth.uid()` vergelijkt gewoon kloppen. Heeft iemand geen
-- account, dan krijgt hij een eigen id dat nooit met een auth-id samenvalt, en
-- matcht hij simpelweg nergens op.
--
-- Bijvangst die we willen: een account opheffen wist de persoon niet meer. Wat
-- iemand op het water heeft laten zien hoort niet te verdwijnen omdat hij zijn
-- login kwijtraakt.
--
-- Wat dit NIET doet: een account koppelen aan iemand die al in het register
-- staat. Krijgt een lid later toch een telefoon, dan levert aanmelden een
-- tweede kaart op. Daar is bewust voor gekozen — leden loggen niet in — en de
-- versie waarin ze dat wel deden staat onder de tag v0.1-leden-met-login.
--
-- Draai na 014-speltakken.sql.

-- ---------------------------------------------------------------- losknippen

alter table profiles drop constraint if exists profiles_id_fkey;
alter table profiles alter column id set default gen_random_uuid();

-- ---------------------------------------------------------------- toevoegen
--
-- Instructeurs mogen dit ook, niet alleen beheerders: wie op de steiger merkt
-- dat er iemand bij is gekomen, moet hem meteen kunnen aanmaken.

create or replace function add_member (p_group uuid, p_name text)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  pid uuid;
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders kunnen leden toevoegen';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Vul een naam in';
  end if;

  insert into profiles (full_name) values (trim(p_name)) returning id into pid;

  -- Altijd als lid. Een instructeur moet kunnen inloggen om af te tekenen, en
  -- daarvoor is een account nodig; die komt binnen met een uitnodigingscode.
  insert into memberships (group_id, profile_id, role) values (p_group, pid, 'lid');

  return pid;
end;
$fn$;

-- ---------------------------------------------------------------- hernoemen
--
-- Iemand zonder account kan zijn eigen naam niet corrigeren, dus moet iemand
-- anders dat kunnen. Begrensd tot de eigen groep.

create or replace function set_member_name (p_group uuid, p_profile uuid, p_name text)
  returns void language plpgsql security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders kunnen een naam aanpassen';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Vul een naam in';
  end if;
  if not exists (
    select 1 from memberships
    where group_id = p_group and profile_id = p_profile
  ) then
    raise exception 'Deze persoon zit niet in de groep';
  end if;

  update profiles
  set full_name = trim(p_name), updated_at = now()
  where id = p_profile;
end;
$fn$;

-- ---------------------------------------------------------------- opruimen
--
-- profiles hing met een cascade aan auth.users, dus een opgeheven account nam
-- het profiel mee. Dat is nu weg, en daarmee ook de enige automatische
-- opruiming. Een los profiel zonder lidmaatschap is verder onschadelijk: het
-- staat in geen enkele lijst, want elke lijst loopt via memberships.

-- ============================================================ 016-bakken-en-standen.sql

-- vinkje — bakken, en aftekenen in drie standen
--
-- Twee dingen die bij elkaar horen, omdat ze samen het overzicht op het water
-- mogelijk maken: één onderdeel kiezen, één bak kiezen, en voor iedereen in die
-- boot in één oogopslag zien en aanpassen hoe ver hij is.
--
-- 1. Bakken. Een vaste bemanning voor het seizoen: "Vlet 1", "Albatros". Niet
--    hetzelfde als een speltak — een speltak is een leeftijdsgroep, een bak is
--    wie er samen in een boot zit. Instructeurs mogen ze beheren, niet alleen
--    beheerders: wie de boten indeelt staat meestal zelf op de steiger.
--
-- 2. Drie standen: niet behandeld, behandeld onderweg, gehaald. "Niet
--    behandeld" is geen rij; de andere twee zijn de kolom status op sign_offs.
--    Alleen "gehaald" telt mee in de voortgang. "Behandeld onderweg" is een
--    geheugensteun voor de instructeur, geen halve aftekening.
--
-- Bestaande aftekeningen worden "gehaald", want dat is wat ze betekenden. En
-- set_sign_off blijft bestaan met zijn aan/uit-parameter: de builds die nu op
-- telefoons staan roepen hem zo aan, en die mogen niet stukgaan tussen deze
-- migratie en de OTA-update die de nieuwe schermen brengt.
--
-- Draai na 015-leden-zonder-account.sql.

-- ---------------------------------------------------------------- standen

do $$ begin
  create type sign_off_status as enum ('behandeld', 'gehaald');
exception when duplicate_object then null;
end $$;

alter table sign_offs
  add column if not exists status sign_off_status not null default 'gehaald';

-- De oude aan/uit-functie, nu met een expliciete stand. Aan is gehaald; wat
-- eerst "behandeld" was en met een oude build wordt aangetikt, wordt gehaald.
create or replace function set_sign_off (
  p_enrollment uuid,
  p_requirement uuid,
  p_signed boolean,
  p_note text default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
begin
  perform set_sign_off_status(
    p_enrollment,
    p_requirement,
    case when p_signed then 'gehaald'::sign_off_status else null end,
    p_note
  );
end;
$fn$;

-- De nieuwe. Null is "niet behandeld" en haalt de rij weg.
--
-- Een notitie blijft staan als er geen nieuwe meekomt: wie een knoop van
-- "onderweg" naar "gehaald" zet, hoort de opmerking "nog een keer bij meer
-- wind" niet kwijt te raken. Een lege string wist hem wel.
create or replace function set_sign_off_status (
  p_enrollment uuid,
  p_requirement uuid,
  p_status sign_off_status,
  p_note text default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  e enrollments%rowtype;
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

  if p_status is null then
    delete from sign_offs
    where enrollment_id = p_enrollment and requirement_id = p_requirement;
    return;
  end if;

  insert into sign_offs (enrollment_id, requirement_id, diploma_id, signed_by, note, status)
  values (
    p_enrollment, p_requirement, e.diploma_id, auth.uid(),
    nullif(trim(coalesce(p_note, '')), ''), p_status
  )
  on conflict (enrollment_id, requirement_id) do update
    set status    = excluded.status,
        signed_by = auth.uid(),
        signed_at = now(),
        note      = case
                      when p_note is null then sign_offs.note
                      else nullif(trim(p_note), '')
                    end;
end;
$fn$;

-- ---------------------------------------------------------------- tellen
--
-- Alleen gehaald telt. Het filter zit in de join, zodat een "behandeld" rij
-- voor de telling niet bestaat.

create or replace view enrollment_progress
  with (security_invoker = true) as
  select
    e.id                                           as enrollment_id,
    count(r.id) filter (where r.kind = 'praktijk') as praktijk_total,
    count(s.id) filter (where r.kind = 'praktijk') as praktijk_done,
    count(r.id) filter (where r.kind = 'theorie')  as theorie_total,
    count(s.id) filter (where r.kind = 'theorie')  as theorie_done,
    count(r.id)                                    as total,
    count(s.id)                                    as done
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id and r.parent_id is null
  left join sign_offs s
    on s.enrollment_id = e.id and s.requirement_id = r.id and s.status = 'gehaald'
  group by e.id;

create or replace function member_enrollments (p_group uuid, p_profile uuid default null)
  returns table (
    enrollment_id    uuid,
    profile_id       uuid,
    full_name        text,
    diploma_id       uuid,
    diploma_code     text,
    diploma_name     text,
    level_label      text,
    discipline_code  text,
    discipline_name  text,
    theory_valid_months int,
    started_on       date,
    theory_passed_on date,
    awarded_on       date,
    note             text,
    praktijk_total   bigint,
    praktijk_done    bigint,
    theorie_total    bigint,
    theorie_done     bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    e.id, e.profile_id, p.full_name,
    d.id, d.code, d.name, d.level_label,
    disc.code, disc.name, d.theory_valid_months,
    e.started_on, e.theory_passed_on, e.awarded_on, e.note,
    count(r.id) filter (where r.kind = 'praktijk'),
    count(s.id) filter (where r.kind = 'praktijk'),
    count(r.id) filter (where r.kind = 'theorie'),
    count(s.id) filter (where r.kind = 'theorie')
  from enrollments e
  join profiles p on p.id = e.profile_id
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  join requirements r on r.diploma_id = d.id and r.parent_id is null
  left join sign_offs s
    on s.enrollment_id = e.id and s.requirement_id = r.id and s.status = 'gehaald'
  where e.group_id = p_group
    and e.profile_id = coalesce(p_profile, auth.uid())
    and (is_staff(p_group) or coalesce(p_profile, auth.uid()) = auth.uid())
    and is_member(p_group)
  group by e.id, p.full_name, d.id, disc.id
  order by e.awarded_on nulls first, disc.sort_order, d.sort_order;
$fn$;

-- De aftekenlijst geeft de stand mee. Nieuwe kolom, dus opnieuw aanmaken.
drop function if exists enrollment_sheet (uuid);

create or replace function enrollment_sheet (p_enrollment uuid)
  returns table (
    requirement_id uuid,
    parent_id      uuid,
    kind           requirement_kind,
    "position"     int,
    title          text,
    detail         text,
    signed_at      timestamptz,
    signed_by      uuid,
    signed_by_name text,
    note           text,
    status         sign_off_status
  )
  language sql stable security definer set search_path = public as $fn$
  select
    r.id, r.parent_id, r.kind, r.position, r.title, r.detail,
    s.signed_at, s.signed_by, sp.full_name, s.note, s.status
  from enrollments e
  join requirements r on r.diploma_id = e.diploma_id
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  left join profiles sp on sp.id = s.signed_by
  where e.id = p_enrollment
    and (is_staff(e.group_id) or e.profile_id = auth.uid())
  order by
    r.kind,
    coalesce((select p.position from requirements p where p.id = r.parent_id), r.position),
    r.parent_id nulls first,
    r.position;
$fn$;

-- ---------------------------------------------------------------- bakken

create table if not exists crews (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups (id) on delete cascade,
  name       text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (group_id, name)
);

create index if not exists crews_group_id_idx on crews (group_id);

-- Via het lidmaatschap, niet het profiel: wie uit de groep gaat, gaat ook uit
-- zijn bak, zonder dat iemand eraan hoeft te denken.
create table if not exists crew_members (
  crew_id       uuid not null references crews (id) on delete cascade,
  membership_id uuid not null references memberships (id) on delete cascade,
  primary key (crew_id, membership_id)
);

create index if not exists crew_members_membership_id_idx on crew_members (membership_id);

create or replace function crew_group (cid uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from crews where id = cid;
$fn$;

alter table crews enable row level security;
alter table crew_members enable row level security;

drop policy if exists crews_read on crews;
create policy crews_read on crews
  for select to authenticated using (is_member(group_id));

drop policy if exists crews_staff_write on crews;
create policy crews_staff_write on crews
  for all to authenticated
  using (is_staff(group_id)) with check (is_staff(group_id));

drop policy if exists crew_members_read on crew_members;
create policy crew_members_read on crew_members
  for select to authenticated using (is_member(crew_group(crew_id)));

-- Indelen gaat alleen via set_crew_members: de hele bemanning in één keer, en
-- met de controle dat iedereen bij de groep hoort. Er is dus geen
-- schrijf-policy op crew_members.

create or replace function set_crew_members (p_crew uuid, p_profiles uuid[])
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  gid uuid;
begin
  gid := crew_group(p_crew);
  if gid is null then
    raise exception 'Deze bak bestaat niet';
  end if;
  if not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders kunnen een bak indelen';
  end if;

  if exists (
    select 1
    from unnest(coalesce(p_profiles, '{}'::uuid[])) as given(id)
    where not exists (
      select 1 from memberships m where m.group_id = gid and m.profile_id = given.id
    )
  ) then
    raise exception 'Iemand in deze lijst hoort niet bij de groep';
  end if;

  delete from crew_members where crew_id = p_crew;

  insert into crew_members (crew_id, membership_id)
  select p_crew, m.id
  from memberships m
  where m.group_id = gid
    and m.profile_id = any (coalesce(p_profiles, '{}'::uuid[]));
end;
$fn$;

-- Wie er in een bak zit, voor het indeelscherm.
create or replace function crew_roster (p_crew uuid)
  returns table (profile_id uuid, full_name text)
  language sql stable security definer set search_path = public as $fn$
  select p.id, p.full_name
  from crews c
  join crew_members cm on cm.crew_id = c.id
  join memberships m on m.id = cm.membership_id
  join profiles p on p.id = m.profile_id
  where c.id = p_crew and is_member(c.group_id)
  order by p.full_name;
$fn$;

-- ---------------------------------------------------------------- het overzicht

-- De diploma's waar iemand in deze bak mee bezig is. Zo toont de keuzelijst
-- in het overzicht alleen wat voor deze boot ertoe doet, niet alle twaalf.
create or replace function crew_diplomas (p_crew uuid)
  returns table (
    diploma_id      uuid,
    diploma_name    text,
    discipline_name text,
    enrolled        bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select d.id, d.name, disc.name, count(distinct e.profile_id)
  from crews c
  join crew_members cm on cm.crew_id = c.id
  join memberships m on m.id = cm.membership_id
  join enrollments e
    on e.group_id = c.group_id and e.profile_id = m.profile_id and e.awarded_on is null
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  where c.id = p_crew and is_staff(c.group_id)
  group by d.id, disc.id
  order by disc.sort_order, d.sort_order;
$fn$;

-- Iedereen in een bak, met zijn stand op één eis of onderdeel. Wie niet voor
-- dat diploma is ingeschreven komt wel mee, met een lege enrollment_id: het
-- scherm laat hem dan zien in plaats van hem stil weg te laten, want "waarom
-- staat Piet er niet bij" is een vraag die je op het water niet wilt krijgen.
create or replace function crew_sheet (p_crew uuid, p_requirement uuid)
  returns table (
    profile_id     uuid,
    full_name      text,
    enrollment_id  uuid,
    status         sign_off_status,
    signed_at      timestamptz,
    signed_by_name text,
    note           text
  )
  language sql stable security definer set search_path = public as $fn$
  select
    p.id, p.full_name, e.id,
    s.status, s.signed_at, sp.full_name, s.note
  from crews c
  join crew_members cm on cm.crew_id = c.id
  join memberships m on m.id = cm.membership_id
  join profiles p on p.id = m.profile_id
  join requirements r on r.id = p_requirement
  left join enrollments e
    on e.group_id = c.group_id and e.profile_id = p.id and e.diploma_id = r.diploma_id
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  left join profiles sp on sp.id = s.signed_by
  where c.id = p_crew and is_staff(c.group_id)
  order by (e.id is null), p.full_name;
$fn$;

-- ============================================================ 017-account-verwijderen.sql

-- vinkje — je eigen account verwijderen, vanuit de app
--
-- Google en Apple eisen allebei dat wie in een app een account kan maken, dat
-- account ook in de app kan laten verwijderen. Dit is de functie achter die
-- knop.
--
-- Wat er verdwijnt, en dat is precies wat het privacybeleid belooft:
--
--   * de login (auth.users);
--   * de persoon in het register (profiles), en via de cascades daarop zijn
--     lidmaatschappen, speltakken, bakken en zijn eigen voortgang;
--   * op aftekeningen die hij als instructeur bij anderen zette blijft staan
--     dát ze gezet zijn, maar niet meer door wie: sign_offs.signed_by is
--     "on delete set null", en de vaarder houdt zijn aftekening.
--
-- Twee deletes, omdat account en persoon sinds 015 los van elkaar staan: het
-- ene weghalen raakt het andere niet meer.
--
-- De laatste beheerder van een groep kan dit niet. Dezelfde regel als bij het
-- degraderen (011) en het verwijderen door een ander (013): anders blijft er een
-- groep achter die niemand meer kan beheren.
--
-- Draai na 016-bakken-en-standen.sql.

create or replace function delete_my_account ()
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'niet ingelogd';
  end if;

  if exists (
    select 1
    from memberships m
    where m.profile_id = me
      and m.role = 'beheerder'
      and not exists (
        select 1 from memberships o
        where o.group_id = m.group_id and o.role = 'beheerder' and o.profile_id <> me
      )
  ) then
    raise exception
      'Je bent de laatste beheerder van je groep. Maak eerst iemand anders beheerder, dan kun je je account verwijderen.';
  end if;

  delete from profiles where id = me;
  delete from auth.users where id = me;
end;
$fn$;

-- ============================================================ 018-eigen-lijsten.sql

-- vinkje — eigen eisenlijsten naast de landelijke catalogus
--
-- Tot nu toe was er één catalogus, van niemand: de landelijke CWO/Watersport
-- Academy-eisen, gelijk voor elke groep, en daarom zonder group_id. Dat klopt
-- nog steeds voor die eisen, maar het is niet alles wat een groep aftekent. Er
-- is een bemanningslid-insigne, er is een herfstkamp waarin een vlet een
-- verkorte lijst afwerkt, en dat hoort nergens.
--
-- Dus komt er een tweede soort lijst ernaast:
--
--   group_id is null      landelijk. Van niemand, voor iedereen zichtbaar, en
--                         alleen te wijzigen door 010-eisen.sql opnieuw te
--                         draaien.
--   group_id is not null  van één groep. Alleen die groep ziet hem, en zijn
--                         instructeurs en beheerders mogen hem bewerken.
--
-- Dat het onderscheid één kolom is en geen tweede tabel, is met opzet: een
-- aftekening, een inschrijving en de voortgangsberekening kijken niet of een
-- eis landelijk is. Alles wat er al staat blijft werken.
--
-- Wat hierbij verdwijnt: sinds 013 mocht een beheerder de landelijke catalogus
-- bewerken vanuit de beheerpagina. Dat was te ruim — die wijziging gold voor
-- élke groep in deze database, en inmiddels deelt een tweede app hetzelfde
-- project. Landelijk is weer alleen-lezen; wie iets aan de landelijke eisen wil
-- veranderen, doet dat in 010-eisen.sql.
--
-- Draai na 017-account-verwijderen.sql.

-- ------------------------------------------------------------------ kolommen

do $$
begin
  if not exists (select 1 from pg_type where typname = 'list_kind') then
    create type list_kind as enum ('diploma', 'insigne');
  end if;
end;
$$;

alter table diplomas
  add column if not exists group_id uuid references groups (id) on delete cascade,
  add column if not exists kind list_kind not null default 'diploma';

create index if not exists diplomas_group_id_idx on diplomas (group_id);

-- Een eigen lijst hangt niet onder een landelijke discipline (Roeien, Zeilen,
-- Buitenboordmotor): die zijn van de CWO. Hij staat op zichzelf, onder zijn
-- eigen kopje in de app.
alter table diplomas alter column discipline_id drop not null;

alter table diplomas drop constraint if exists diplomas_eigen_of_landelijk;
alter table diplomas add constraint diplomas_eigen_of_landelijk check (
  (group_id is null and discipline_id is not null) or
  (group_id is not null and discipline_id is null)
);

-- ------------------------------------------------------------------ zichtbaar
--
-- Lezen: de landelijke lijst voor iedereen die is ingelogd, een eigen lijst
-- alleen voor de groep zelf.

drop policy if exists diplomas_read on diplomas;
create policy diplomas_read on diplomas
  for select to authenticated
  using (group_id is null or is_member(group_id));

drop policy if exists requirements_read on requirements;
create policy requirements_read on requirements
  for select to authenticated
  using (exists (
    select 1 from diplomas d
    where d.id = requirements.diploma_id
      and (d.group_id is null or is_member(d.group_id))
  ));

-- ------------------------------------------------------------------ schrijven
--
-- De brede policies uit 013 gaven élke beheerder de hele catalogus. Weg ermee.
-- Schrijven mag alleen op een lijst die van je eigen groep is; de landelijke
-- rijen vallen buiten elke write-policy en zijn daarmee onaanraakbaar.

drop policy if exists disciplines_admin_write on disciplines;
drop policy if exists diplomas_admin_write on diplomas;
drop policy if exists requirements_admin_write on requirements;

drop policy if exists diplomas_own_write on diplomas;
create policy diplomas_own_write on diplomas
  for all to authenticated
  using (group_id is not null and is_staff(group_id))
  with check (group_id is not null and is_staff(group_id));

drop policy if exists requirements_own_write on requirements;
create policy requirements_own_write on requirements
  for all to authenticated
  using (exists (
    select 1 from diplomas d
    where d.id = requirements.diploma_id
      and d.group_id is not null and is_staff(d.group_id)
  ))
  with check (exists (
    select 1 from diplomas d
    where d.id = requirements.diploma_id
      and d.group_id is not null and is_staff(d.group_id)
  ));

-- ------------------------------------------------------------------ aanmaken

-- Codes zijn er voor 010-eisen.sql, dat op `code` bijwerkt. Een eigen lijst
-- wordt nooit door dat bestand aangeraakt, dus krijgt hij een code die er
-- gegarandeerd niet mee botst.
create or replace function own_code (p_prefix text)
  returns text language sql volatile set search_path = public as $fn$
  select p_prefix || replace(gen_random_uuid()::text, '-', '');
$fn$;

-- Een lege lijst: voor een insigne of iets wat nergens op lijkt.
create or replace function create_own_list (
  p_group   uuid,
  p_name    text,
  p_kind    list_kind default 'diploma',
  p_summary text default null
)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  new_id uuid;
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders kunnen een eigen lijst maken';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Vul een naam in';
  end if;

  insert into diplomas (discipline_id, group_id, kind, code, name, summary, sort_order)
  values (null, p_group, p_kind, own_code('eigen-'), trim(p_name), nullif(trim(p_summary), ''),
          coalesce((select max(sort_order) + 1 from diplomas where group_id = p_group), 1))
  returning id into new_id;

  return new_id;
end;
$fn$;

-- Kopiëren en inkorten: de gewone weg voor "hetzelfde als Roeien I/II, maar
-- korter". De kopie staat helemaal los van het origineel — schrappen in de
-- kopie raakt de landelijke lijst niet, en andersom.
create or replace function copy_list_to_group (
  p_group  uuid,
  p_source uuid,
  p_name   text default null,
  p_kind   list_kind default 'diploma'
)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  bron   diplomas%rowtype;
  new_id uuid;
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders kunnen een eigen lijst maken';
  end if;

  select * into bron from diplomas where id = p_source;
  if not found then
    raise exception 'Die lijst bestaat niet';
  end if;
  if bron.group_id is not null and not is_member(bron.group_id) then
    raise exception 'Die lijst bestaat niet';
  end if;

  insert into diplomas (discipline_id, group_id, kind, code, name, level_label, summary,
                        theory_valid_months, source, sort_order)
  values (null, p_group, p_kind, own_code('eigen-'),
          coalesce(nullif(trim(p_name), ''), bron.name || ' (eigen)'),
          bron.level_label, bron.summary, bron.theory_valid_months,
          coalesce(bron.source, bron.name),
          coalesce((select max(sort_order) + 1 from diplomas where group_id = p_group), 1))
  returning id into new_id;

  -- Eerst de eisen, dan de onderdelen. Een onderdeel vindt zijn nieuwe ouder
  -- terug op soort en nummer: die twee zijn binnen een lijst uniek (zie de
  -- index requirements_top_position uit 012), dus dat wijst altijd één rij aan.
  insert into requirements (diploma_id, code, kind, "position", title, detail)
  select new_id, own_code('eigen-'), b.kind, b."position", b.title, b.detail
  from requirements b
  where b.diploma_id = p_source and b.parent_id is null;

  insert into requirements (diploma_id, code, kind, "position", title, detail, parent_id)
  select new_id, own_code('eigen-'), o.kind, o."position", o.title, o.detail, nieuwe_ouder.id
  from requirements o
  join requirements oude_ouder on oude_ouder.id = o.parent_id
  join requirements nieuwe_ouder
    on nieuwe_ouder.diploma_id = new_id
   and nieuwe_ouder.parent_id is null
   and nieuwe_ouder.kind = oude_ouder.kind
   and nieuwe_ouder."position" = oude_ouder."position"
  where o.diploma_id = p_source and o.parent_id is not null;

  return new_id;
end;
$fn$;

-- ------------------------------------------------------------------ bijwerken

create or replace function own_list_group (p_diploma uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from diplomas where id = p_diploma;
$fn$;

create or replace function assert_own_list (p_diploma uuid)
  returns uuid language plpgsql stable security definer set search_path = public as $fn$
declare
  gid uuid := own_list_group(p_diploma);
begin
  if gid is null then
    raise exception 'Dit is een landelijke lijst. Die kun je niet aanpassen; maak er een eigen kopie van.';
  end if;
  if not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen dit aanpassen';
  end if;
  return gid;
end;
$fn$;

create or replace function update_own_list (
  p_diploma uuid,
  p_name    text,
  p_kind    list_kind default null,
  p_summary text default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
begin
  perform assert_own_list(p_diploma);
  if coalesce(trim(p_name), '') = '' then
    raise exception 'Vul een naam in';
  end if;

  update diplomas
  set name    = trim(p_name),
      kind    = coalesce(p_kind, kind),
      summary = nullif(trim(p_summary), '')
  where id = p_diploma;
end;
$fn$;

-- Weggooien mag pas als er niemand meer aan werkt: anders verdwijnt met de
-- lijst ook de voortgang van iedereen die hem volgde, zonder waarschuwing.
create or replace function delete_own_list (p_diploma uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  bezig int;
begin
  perform assert_own_list(p_diploma);

  select count(*) into bezig from enrollments where diploma_id = p_diploma;
  if bezig = 1 then
    raise exception 'Er werkt nog iemand aan deze lijst. Haal die opleiding eerst weg.';
  elsif bezig > 1 then
    raise exception 'Er werken nog % mensen aan deze lijst. Haal die opleidingen eerst weg.', bezig;
  end if;

  delete from diplomas where id = p_diploma;
end;
$fn$;

-- ------------------------------------------------------------------ eisen

create or replace function add_own_requirement (
  p_diploma uuid,
  p_kind    requirement_kind,
  p_title   text,
  p_detail  text default null,
  p_parent  uuid default null
)
  returns uuid language plpgsql security definer set search_path = public as $fn$
declare
  new_id uuid;
  pos    int;
  soort  requirement_kind := p_kind;
begin
  perform assert_own_list(p_diploma);
  if coalesce(trim(p_title), '') = '' then
    raise exception 'Vul een omschrijving in';
  end if;

  if p_parent is not null then
    -- Een onderdeel hoort bij zijn eis: zelfde lijst, zelfde soort.
    select r.kind into soort from requirements r
    where r.id = p_parent and r.diploma_id = p_diploma;
    if not found then
      raise exception 'Die eis hoort niet bij deze lijst';
    end if;
    select coalesce(max("position") + 1, 1) into pos
    from requirements where parent_id = p_parent;
  else
    select coalesce(max("position") + 1, 1) into pos
    from requirements where diploma_id = p_diploma and kind = soort and parent_id is null;
  end if;

  insert into requirements (diploma_id, code, kind, "position", title, detail, parent_id)
  values (p_diploma, own_code('eigen-'), soort, pos, trim(p_title),
          nullif(trim(p_detail), ''), p_parent)
  returning id into new_id;

  return new_id;
end;
$fn$;

create or replace function update_own_requirement (
  p_requirement uuid,
  p_title       text,
  p_detail      text default null
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  dip uuid;
begin
  select diploma_id into dip from requirements where id = p_requirement;
  if not found then
    raise exception 'Die eis bestaat niet';
  end if;
  perform assert_own_list(dip);
  if coalesce(trim(p_title), '') = '' then
    raise exception 'Vul een omschrijving in';
  end if;

  update requirements
  set title = trim(p_title), detail = nullif(trim(p_detail), '')
  where id = p_requirement;
end;
$fn$;

-- Verwijderen sluit het gat in de nummering, anders loopt de volgende toevoeging
-- tegen de unieke index aan.
create or replace function delete_own_requirement (p_requirement uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  r requirements%rowtype;
begin
  select * into r from requirements where id = p_requirement;
  if not found then
    return;
  end if;
  perform assert_own_list(r.diploma_id);

  delete from requirements where id = p_requirement;

  if r.parent_id is null then
    update requirements
    set "position" = "position" - 1
    where diploma_id = r.diploma_id and kind = r.kind and parent_id is null
      and "position" > r."position";
  else
    update requirements
    set "position" = "position" - 1
    where parent_id = r.parent_id and "position" > r."position";
  end if;
end;
$fn$;

-- Volgorde: de lijst zoals hij op het scherm hoort te staan, in één keer.
-- Eerst naar negatieve nummers, anders botst een wissel met de unieke index.
create or replace function set_own_requirement_order (
  p_diploma uuid,
  p_kind    requirement_kind,
  p_parent  uuid,
  p_ids     uuid[]
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  i int;
begin
  perform assert_own_list(p_diploma);

  update requirements set "position" = -"position"
  where diploma_id = p_diploma
    and id = any (p_ids)
    and ((p_parent is null and parent_id is null and kind = p_kind)
      or (p_parent is not null and parent_id = p_parent));

  for i in 1 .. coalesce(array_length(p_ids, 1), 0) loop
    update requirements set "position" = i
    where id = p_ids[i] and diploma_id = p_diploma and "position" < 0;
  end loop;

  if exists (
    select 1 from requirements
    where diploma_id = p_diploma and "position" < 0
  ) then
    raise exception 'De volgorde moet alle eisen noemen';
  end if;
end;
$fn$;

-- ------------------------------------------------------------------ overzicht
--
-- catalogue_usage uit 013 telde over alle groepen. Dat hoort niet meer: tel
-- alleen wat in je eigen groepen aan een lijst hangt.
create or replace function catalogue_usage ()
  returns table (
    diploma_id  uuid,
    enrollments bigint,
    sign_offs   bigint
  )
  language sql stable security definer set search_path = public as $fn$
  select
    d.id,
    count(distinct e.id),
    count(s.id)
  from diplomas d
  left join enrollments e on e.diploma_id = d.id and is_staff(e.group_id)
  left join sign_offs s on s.enrollment_id = e.id
  where d.group_id is null or is_member(d.group_id)
  group by d.id;
$fn$;

-- ============================================================ 019-examens.sql

-- vinkje — examens: maken, afnemen met een sessiecode, en meekijken
--
-- Tot nu toe kon in deze database niemand iets zonder in te loggen. Een examen
-- breekt daarmee: de vaarders die het invullen hebben geen account en geen app.
-- Zij komen binnen met een code en een naam, op een webpagina.
--
-- Daarom staat hier één regel boven alles: een deelnemer krijgt géén toegang tot
-- tabellen. Hij mag vijf functies aanroepen, en die controleren zelf alles.
--
--   exam_session_info  wat is dit voor examen (titel, aantal vragen)
--   exam_join          meedoen: naam achterlaten, vragen ophalen
--   exam_answer        één antwoord opslaan
--   exam_submit        inleveren; de score wordt hier berekend, niet in de browser
--   exam_result        je eigen uitslag
--
-- Drie dingen maken dat veilig:
--
--   * Het juiste antwoord verlaat de server nooit. exam_join geeft de vragen
--     zonder `correct` terug; nakijken gebeurt hier.
--   * Elke deelname krijgt een geheim token. Met alleen de code kom je niet bij
--     het werk van een ander.
--   * Een sessie die dicht is of over zijn tijd heen, accepteert niets meer.
--     Een vergeten sessie sluit dus zichzelf.
--
-- Instructeurs en beheerders werken wél gewoon op de tabellen, met dezelfde
-- afspraak als bij de eigen eisenlijsten: alleen die van je eigen groep.
--
-- Draai na 018-eigen-lijsten.sql.

-- ------------------------------------------------------------------ types

do $$
begin
  if not exists (select 1 from pg_type where typname = 'exam_question_kind') then
    create type exam_question_kind as enum ('meerkeuze', 'juist_onjuist');
  end if;
  if not exists (select 1 from pg_type where typname = 'exam_session_status') then
    create type exam_session_status as enum ('open', 'gesloten');
  end if;
end;
$$;

-- ------------------------------------------------------------------ tabellen

create table if not exists exams (
  id           uuid primary key default gen_random_uuid(),
  group_id     uuid not null references groups (id) on delete cascade,
  title        text not null,
  intro        text,
  -- Waar het examen bij hoort. Mag leeg: niet elk examen hangt aan een diploma.
  diploma_id   uuid references diplomas (id) on delete set null,
  pass_percent int not null default 70 check (pass_percent between 0 and 100),
  -- Volgorde schudden per deelnemer, zodat overschrijven weinig oplevert.
  shuffle      boolean not null default true,
  created_by   uuid references profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

create index if not exists exams_group_id_idx on exams (group_id);

create table if not exists exam_questions (
  id       uuid primary key default gen_random_uuid(),
  exam_id  uuid not null references exams (id) on delete cascade,
  position int not null,
  kind     exam_question_kind not null default 'meerkeuze',
  prompt   text not null,
  -- Pad in de opslagmap bij Supabase; het bestand zelf staat niet in de database.
  image_path text,
  points   int not null default 1 check (points > 0),
  unique (exam_id, position),
  unique (id, exam_id)
);

create index if not exists exam_questions_exam_id_idx on exam_questions (exam_id);

create table if not exists exam_options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references exam_questions (id) on delete cascade,
  position    int not null,
  label       text not null,
  correct     boolean not null default false,
  unique (question_id, position),
  unique (id, question_id)
);

create index if not exists exam_options_question_id_idx on exam_options (question_id);

-- Eén afname. De code hoort bij de sessie en niet bij het examen: zo opent een
-- code van vorig seizoen niets meer, terwijl de vragen blijven bestaan.
create table if not exists exam_sessions (
  id          uuid primary key default gen_random_uuid(),
  exam_id     uuid not null references exams (id) on delete cascade,
  group_id    uuid not null references groups (id) on delete cascade,
  code        text not null unique,
  label       text,
  status      exam_session_status not null default 'open',
  show_result boolean not null default true,
  opened_at   timestamptz not null default now(),
  closes_at   timestamptz not null default now() + interval '6 hours',
  closed_at   timestamptz,
  created_by  uuid references profiles (id) on delete set null
);

create index if not exists exam_sessions_exam_id_idx on exam_sessions (exam_id);
create index if not exists exam_sessions_group_id_idx on exam_sessions (group_id);

create table if not exists exam_attempts (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references exam_sessions (id) on delete cascade,
  display_name text not null,
  -- Het geheim dat een deelnemer in zijn browser houdt. Zonder dit token is een
  -- deelname niet te lezen en niet te wijzigen, ook niet door wie de code heeft.
  token        uuid not null default gen_random_uuid(),
  -- Gevuld zodra een instructeur de deelname aan een vaarder koppelt.
  profile_id   uuid references profiles (id) on delete set null,
  order_seed   uuid not null default gen_random_uuid(),
  started_at   timestamptz not null default now(),
  submitted_at timestamptz,
  score        int,
  total        int
);

create index if not exists exam_attempts_session_id_idx on exam_attempts (session_id);

create table if not exists exam_answers (
  attempt_id  uuid not null references exam_attempts (id) on delete cascade,
  question_id uuid not null references exam_questions (id) on delete cascade,
  option_id   uuid references exam_options (id) on delete set null,
  -- Bij het opslaan al nagekeken, zodat inleveren geen rekenwerk meer is.
  correct     boolean not null default false,
  answered_at timestamptz not null default now(),
  primary key (attempt_id, question_id)
);

-- ------------------------------------------------------------------ wie mag wat

create or replace function exam_group (p_exam uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from exams where id = p_exam;
$fn$;

create or replace function exam_session_group (p_session uuid)
  returns uuid language sql stable security definer set search_path = public as $fn$
  select group_id from exam_sessions where id = p_session;
$fn$;

alter table exams          enable row level security;
alter table exam_questions enable row level security;
alter table exam_options   enable row level security;
alter table exam_sessions  enable row level security;
alter table exam_attempts  enable row level security;
alter table exam_answers   enable row level security;

-- Alles van je eigen groep, en niets daarbuiten. Let op wie er níét bij kan: een
-- lid van de groep. Een vaarder die de vragen kan lezen heeft geen examen meer.

drop policy if exists exams_staff on exams;
create policy exams_staff on exams
  for all to authenticated
  using (is_staff(group_id)) with check (is_staff(group_id));

drop policy if exists exam_questions_staff on exam_questions;
create policy exam_questions_staff on exam_questions
  for all to authenticated
  using (is_staff(exam_group(exam_id))) with check (is_staff(exam_group(exam_id)));

drop policy if exists exam_options_staff on exam_options;
create policy exam_options_staff on exam_options
  for all to authenticated
  using (exists (
    select 1 from exam_questions q
    where q.id = exam_options.question_id and is_staff(exam_group(q.exam_id))))
  with check (exists (
    select 1 from exam_questions q
    where q.id = exam_options.question_id and is_staff(exam_group(q.exam_id))));

drop policy if exists exam_sessions_staff on exam_sessions;
create policy exam_sessions_staff on exam_sessions
  for all to authenticated
  using (is_staff(group_id)) with check (is_staff(group_id));

drop policy if exists exam_attempts_staff on exam_attempts;
create policy exam_attempts_staff on exam_attempts
  for all to authenticated
  using (is_staff(exam_session_group(session_id)))
  with check (is_staff(exam_session_group(session_id)));

drop policy if exists exam_answers_staff on exam_answers;
create policy exam_answers_staff on exam_answers
  for all to authenticated
  using (exists (
    select 1 from exam_attempts a
    where a.id = exam_answers.attempt_id and is_staff(exam_session_group(a.session_id))))
  with check (exists (
    select 1 from exam_attempts a
    where a.id = exam_answers.attempt_id and is_staff(exam_session_group(a.session_id))));

-- ------------------------------------------------------------------ sessies

-- Een code om voor te lezen in een clubhuis: geen 0/O, geen 1/I/L, geen U/V.
create or replace function exam_code ()
  returns text language plpgsql volatile set search_path = public as $fn$
declare
  alfabet text := 'ABCDEFGHJKMNPQRSTWXYZ23456789';
  kandidaat text;
  i int;
begin
  loop
    kandidaat := '';
    for i in 1 .. 6 loop
      kandidaat := kandidaat || substr(alfabet, 1 + floor(random() * length(alfabet))::int, 1);
    end loop;
    exit when not exists (select 1 from exam_sessions where code = kandidaat);
  end loop;
  return kandidaat;
end;
$fn$;

create or replace function open_exam_session (
  p_exam        uuid,
  p_label       text default null,
  p_hours       int default 6,
  p_show_result boolean default true
)
  returns table (session_id uuid, code text, closes_at timestamptz)
  language plpgsql security definer set search_path = public as $fn$
declare
  gid uuid := exam_group(p_exam);
  n   int;
begin
  if gid is null or not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen een examen afnemen';
  end if;

  select count(*) into n from exam_questions where exam_id = p_exam;
  if n = 0 then
    raise exception 'Dit examen heeft nog geen vragen';
  end if;

  return query
  insert into exam_sessions (exam_id, group_id, code, label, closes_at, show_result, created_by)
  values (p_exam, gid, exam_code(), nullif(trim(p_label), ''),
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 6), 24))),
          coalesce(p_show_result, true), auth.uid())
  returning exam_sessions.id, exam_sessions.code, exam_sessions.closes_at;
end;
$fn$;

create or replace function close_exam_session (p_session uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
begin
  if not is_staff(exam_session_group(p_session)) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen een sessie sluiten';
  end if;

  update exam_sessions
  set status = 'gesloten', closed_at = now()
  where id = p_session and status = 'open';
end;
$fn$;

-- Eén plek die bepaalt of er nog gewerkt mag worden. Tijd is hier net zo goed
-- een slot als de status: een sessie die iemand vergeet te sluiten, sluit zelf.
create or replace function exam_session_live (p_session uuid)
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from exam_sessions s
    where s.id = p_session and s.status = 'open' and s.closes_at > now()
  );
$fn$;

-- ------------------------------------------------------------------ meedoen
--
-- Vanaf hier: functies die een deelnemer zonder account aanroept.

create or replace function exam_session_info (p_code text)
  returns table (title text, intro text, vragen int, open boolean)
  language sql stable security definer set search_path = public as $fn$
  select e.title, e.intro,
         (select count(*)::int from exam_questions q where q.exam_id = e.id),
         exam_session_live(s.id)
  from exam_sessions s
  join exams e on e.id = s.exam_id
  where s.code = upper(trim(p_code));
$fn$;

-- Meedoen. De vragen komen hier pas naar buiten — en zonder het juiste antwoord.
create or replace function exam_join (p_code text, p_name text)
  returns table (attempt_id uuid, token uuid, title text, intro text, questions jsonb)
  language plpgsql security definer set search_path = public as $fn$
declare
  s        exam_sessions%rowtype;
  e        exams%rowtype;
  poging   exam_attempts%rowtype;
  naam     text := nullif(trim(p_name), '');
begin
  select * into s from exam_sessions where code = upper(trim(p_code));
  if not found then
    raise exception 'Deze code kennen we niet';
  end if;
  if not exam_session_live(s.id) then
    raise exception 'Dit examen is gesloten';
  end if;
  if naam is null or length(naam) < 2 then
    raise exception 'Vul je naam in';
  end if;
  if length(naam) > 60 then
    raise exception 'Die naam is te lang';
  end if;
  -- Een rem op onzin: een klas is geen tweehonderd man.
  if (select count(*) from exam_attempts a where a.session_id = s.id) >= 200 then
    raise exception 'Er zitten al te veel deelnemers in deze sessie';
  end if;

  select * into e from exams where id = s.exam_id;

  insert into exam_attempts (session_id, display_name)
  values (s.id, naam)
  returning * into poging;

  return query
  select poging.id, poging.token, e.title, e.intro,
    coalesce(jsonb_agg(v.vraag order by v.volgorde), '[]'::jsonb)
  from (
    select
      case when e.shuffle
        then md5(poging.order_seed::text || q.id::text)
        else lpad(q.position::text, 6, '0')
      end as volgorde,
      jsonb_build_object(
        'id', q.id,
        'kind', q.kind,
        'prompt', q.prompt,
        'image_path', q.image_path,
        'points', q.points,
        'options', (
          select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label)
                          order by case when e.shuffle
                                     then md5(poging.order_seed::text || o.id::text)
                                     else lpad(o.position::text, 6, '0') end), '[]'::jsonb)
          from exam_options o where o.question_id = q.id
        )
      ) as vraag
    from exam_questions q
    where q.exam_id = e.id
  ) as v;
end;
$fn$;

-- Een deelname terugvinden, mét het token. Elke functie hieronder begint hiermee.
create or replace function exam_attempt_of (p_attempt uuid, p_token uuid)
  returns exam_attempts language plpgsql stable security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype;
begin
  select * into poging from exam_attempts
  where id = p_attempt and token = p_token;
  if not found then
    raise exception 'Deze deelname kennen we niet';
  end if;
  return poging;
end;
$fn$;

create or replace function exam_answer (
  p_attempt  uuid,
  p_token    uuid,
  p_question uuid,
  p_option   uuid
)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  goed   boolean;
begin
  if poging.submitted_at is not null then
    raise exception 'Je hebt dit examen al ingeleverd';
  end if;
  if not exam_session_live(poging.session_id) then
    raise exception 'Dit examen is gesloten';
  end if;

  -- De vraag moet bij dít examen horen en het antwoord bij díe vraag. Zonder
  -- deze twee controles kan iemand met een geldig token antwoorden uit een
  -- ander examen naar binnen schuiven.
  if not exists (
    select 1
    from exam_questions q
    join exam_sessions s on s.exam_id = q.exam_id
    where q.id = p_question and s.id = poging.session_id
  ) then
    raise exception 'Deze vraag hoort niet bij dit examen';
  end if;

  select o.correct into goed
  from exam_options o
  where o.id = p_option and o.question_id = p_question;

  if p_option is not null and goed is null then
    raise exception 'Dit antwoord hoort niet bij deze vraag';
  end if;

  insert into exam_answers (attempt_id, question_id, option_id, correct)
  values (p_attempt, p_question, p_option, coalesce(goed, false))
  on conflict (attempt_id, question_id) do update
  set option_id = excluded.option_id,
      correct   = excluded.correct,
      answered_at = now();
end;
$fn$;

create or replace function exam_submit (p_attempt uuid, p_token uuid)
  returns table (score int, total int, percent int, passed boolean, show_result boolean)
  language plpgsql security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  s      exam_sessions%rowtype;
  e      exams%rowtype;
  behaald int;
  maximum int;
begin
  select * into s from exam_sessions where id = poging.session_id;
  select * into e from exams where id = s.exam_id;

  if poging.submitted_at is null then
    if not exam_session_live(s.id) then
      raise exception 'Dit examen is gesloten';
    end if;

    select
      coalesce(sum(q.points) filter (where a.correct), 0),
      coalesce(sum(q.points), 0)
    into behaald, maximum
    from exam_questions q
    left join exam_answers a on a.question_id = q.id and a.attempt_id = poging.id
    where q.exam_id = e.id;

    update exam_attempts
    set submitted_at = now(), score = behaald, total = maximum
    where id = poging.id
    returning * into poging;
  end if;

  return query
  select poging.score, poging.total,
         case when poging.total > 0
           then round(poging.score * 100.0 / poging.total)::int else 0 end,
         case when poging.total > 0
           then (poging.score * 100.0 / poging.total) >= e.pass_percent else false end,
         s.show_result;
end;
$fn$;

create or replace function exam_result (p_attempt uuid, p_token uuid)
  returns table (score int, total int, percent int, passed boolean, show_result boolean)
  language plpgsql stable security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  s      exam_sessions%rowtype;
  e      exams%rowtype;
begin
  select * into s from exam_sessions where id = poging.session_id;
  select * into e from exams where id = s.exam_id;

  if poging.submitted_at is null then
    raise exception 'Dit examen is nog niet ingeleverd';
  end if;

  return query
  select poging.score, poging.total,
         case when poging.total > 0
           then round(poging.score * 100.0 / poging.total)::int else 0 end,
         case when poging.total > 0
           then (poging.score * 100.0 / poging.total) >= e.pass_percent else false end,
         s.show_result;
end;
$fn$;

-- ------------------------------------------------------------------ meekijken

create or replace function exam_session_overview (p_session uuid)
  returns table (
    attempt_id   uuid,
    display_name text,
    profile_id   uuid,
    started_at   timestamptz,
    submitted_at timestamptz,
    beantwoord   int,
    vragen       int,
    score        int,
    total        int
  )
  language sql stable security definer set search_path = public as $fn$
  select
    a.id, a.display_name, a.profile_id, a.started_at, a.submitted_at,
    (select count(*)::int from exam_answers x where x.attempt_id = a.id and x.option_id is not null),
    (select count(*)::int from exam_questions q
     join exam_sessions s2 on s2.exam_id = q.exam_id where s2.id = a.session_id),
    a.score, a.total
  from exam_attempts a
  where a.session_id = p_session
    and is_staff(exam_session_group(a.session_id))
  order by a.started_at;
$fn$;

create or replace function exam_attempt_detail (p_attempt uuid)
  returns table (
    question_id uuid,
    "position"  int,
    prompt      text,
    gekozen     text,
    juiste      text,
    correct     boolean
  )
  language sql stable security definer set search_path = public as $fn$
  select
    q.id, q.position, q.prompt,
    (select o.label from exam_options o where o.id = a.option_id),
    (select string_agg(o.label, ', ' order by o.position)
     from exam_options o where o.question_id = q.id and o.correct),
    coalesce(a.correct, false)
  from exam_attempts att
  join exam_sessions s on s.id = att.session_id
  join exam_questions q on q.exam_id = s.exam_id
  left join exam_answers a on a.attempt_id = att.id and a.question_id = q.id
  where att.id = p_attempt
    and is_staff(exam_session_group(att.session_id))
  order by q.position;
$fn$;

-- Een deelname aan een vaarder hangen, zodat je hem later kunt aftekenen. Het
-- aftekenen zelf blijft handwerk: een fout in een vraag hoort niet vanzelf in
-- iemands vorderingenstaat terecht te komen.
create or replace function exam_attempt_link (p_attempt uuid, p_profile uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
declare
  gid uuid;
begin
  select exam_session_group(a.session_id) into gid
  from exam_attempts a where a.id = p_attempt;

  if gid is null or not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen dit koppelen';
  end if;

  if p_profile is not null and not exists (
    select 1 from memberships m where m.group_id = gid and m.profile_id = p_profile
  ) then
    raise exception 'Deze persoon zit niet in de groep';
  end if;

  update exam_attempts set profile_id = p_profile where id = p_attempt;
end;
$fn$;

create or replace function exam_attempt_remove (p_attempt uuid)
  returns void language plpgsql security definer set search_path = public as $fn$
begin
  if not exists (
    select 1 from exam_attempts a
    where a.id = p_attempt and is_staff(exam_session_group(a.session_id))
  ) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen dit weghalen';
  end if;

  delete from exam_attempts where id = p_attempt;
end;
$fn$;

-- ============================================================ 020-examen-nakijken.sql

-- vinkje — na afloop zien wat goed en fout was
--
-- Een uitslag van "8 van de 12" zegt een vaarder weinig. Hij wil weten welke
-- vier. Daarom mag een sessie na het inleveren de antwoorden teruggeven.
--
-- Waarom dat een knop per sessie is en niet altijd aan: wie de antwoorden ziet,
-- kan ze doorvertellen aan wie nog moet. Bij een toets in de klas wil je dat
-- pas als iedereen klaar is; bij zelf oefenen juist meteen.
--
-- Draai na 019-examens.sql.

alter table exam_sessions
  add column if not exists show_answers boolean not null default true;

-- open_exam_session krijgt er een keuze bij. Eerst de oude weg, anders bestaan
-- er twee functies met dezelfde naam en weet PostgREST niet welke je bedoelt.
drop function if exists open_exam_session (uuid, text, int, boolean);

create or replace function open_exam_session (
  p_exam         uuid,
  p_label        text default null,
  p_hours        int default 6,
  p_show_result  boolean default true,
  p_show_answers boolean default true
)
  returns table (session_id uuid, code text, closes_at timestamptz)
  language plpgsql security definer set search_path = public as $fn$
declare
  gid uuid := exam_group(p_exam);
  n   int;
begin
  if gid is null or not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen een examen afnemen';
  end if;

  select count(*) into n from exam_questions where exam_id = p_exam;
  if n = 0 then
    raise exception 'Dit examen heeft nog geen vragen';
  end if;

  return query
  insert into exam_sessions (exam_id, group_id, code, label, closes_at,
                             show_result, show_answers, created_by)
  values (p_exam, gid, exam_code(), nullif(trim(p_label), ''),
          now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 6), 24))),
          coalesce(p_show_result, true), coalesce(p_show_answers, true), auth.uid())
  returning exam_sessions.id, exam_sessions.code, exam_sessions.closes_at;
end;
$fn$;

-- Nakijken voor de deelnemer zelf. Pas na het inleveren, en alleen als de
-- sessie het toestaat: anders is dit een sluiproute naar de antwoorden voor wie
-- nog bezig is.
create or replace function exam_review (p_attempt uuid, p_token uuid)
  returns table (
    "position" int,
    prompt     text,
    gekozen    text,
    juiste     text,
    correct    boolean
  )
  language plpgsql stable security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  s      exam_sessions%rowtype;
begin
  select * into s from exam_sessions where id = poging.session_id;

  if poging.submitted_at is null then
    raise exception 'Dit examen is nog niet ingeleverd';
  end if;
  if not s.show_answers then
    raise exception 'Je instructeur bespreekt de antwoorden met je';
  end if;

  return query
  select q.position, q.prompt,
    (select o.label from exam_options o where o.id = a.option_id),
    (select string_agg(o.label, ', ' order by o.position)
     from exam_options o where o.question_id = q.id and o.correct),
    coalesce(a.correct, false)
  from exam_questions q
  left join exam_answers a on a.question_id = q.id and a.attempt_id = poging.id
  where q.exam_id = s.exam_id
  order by q.position;
end;
$fn$;

-- exam_submit en exam_result zeggen er meteen bij of nakijken mag, zodat de
-- pagina weet of hij de knop moet tonen. Er komt een kolom bij in wat ze
-- teruggeven, en dat kan Postgres niet met "create or replace": eerst weg.
drop function if exists exam_submit (uuid, uuid);
drop function if exists exam_result (uuid, uuid);

create or replace function exam_submit (p_attempt uuid, p_token uuid)
  returns table (score int, total int, percent int, passed boolean,
                 show_result boolean, show_answers boolean)
  language plpgsql security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  s      exam_sessions%rowtype;
  e      exams%rowtype;
  behaald int;
  maximum int;
begin
  select * into s from exam_sessions where id = poging.session_id;
  select * into e from exams where id = s.exam_id;

  if poging.submitted_at is null then
    if not exam_session_live(s.id) then
      raise exception 'Dit examen is gesloten';
    end if;

    select
      coalesce(sum(q.points) filter (where a.correct), 0),
      coalesce(sum(q.points), 0)
    into behaald, maximum
    from exam_questions q
    left join exam_answers a on a.question_id = q.id and a.attempt_id = poging.id
    where q.exam_id = e.id;

    update exam_attempts
    set submitted_at = now(), score = behaald, total = maximum
    where id = poging.id
    returning * into poging;
  end if;

  return query
  select poging.score, poging.total,
         case when poging.total > 0
           then round(poging.score * 100.0 / poging.total)::int else 0 end,
         case when poging.total > 0
           then (poging.score * 100.0 / poging.total) >= e.pass_percent else false end,
         s.show_result, s.show_answers;
end;
$fn$;

create or replace function exam_result (p_attempt uuid, p_token uuid)
  returns table (score int, total int, percent int, passed boolean,
                 show_result boolean, show_answers boolean)
  language plpgsql stable security definer set search_path = public as $fn$
declare
  poging exam_attempts%rowtype := exam_attempt_of(p_attempt, p_token);
  s      exam_sessions%rowtype;
  e      exams%rowtype;
begin
  select * into s from exam_sessions where id = poging.session_id;
  select * into e from exams where id = s.exam_id;

  if poging.submitted_at is null then
    raise exception 'Dit examen is nog niet ingeleverd';
  end if;

  return query
  select poging.score, poging.total,
         case when poging.total > 0
           then round(poging.score * 100.0 / poging.total)::int else 0 end,
         case when poging.total > 0
           then (poging.score * 100.0 / poging.total) >= e.pass_percent else false end,
         s.show_result, s.show_answers;
end;
$fn$;

-- ============================================================ 021-examenvraag-bij-eis.sql

-- vinkje — een examenvraag mag bij een eis horen
--
-- Een theorie-examen gaat over de eisen die toch al in de app staan. Als een
-- vraag weet bij welke eis hij hoort, levert dat twee dingen op:
--
--   * je bouwt een examen door eisen aan te vinken, in plaats van ze over te
--     typen;
--   * een uitslag is later terug te vertalen naar de vorderingenstaat: deze
--     vaarder had de vragen bij eis 3 en 5 goed.
--
-- De koppeling is losjes: `on delete set null`. Verdwijnt een eis uit de
-- catalogus, dan blijft de vraag gewoon bestaan — een afgenomen examen hoort
-- niet te veranderen omdat iemand later in de eisenlijst schoonmaakt.
--
-- Draai na 020-examen-nakijken.sql.

alter table exam_questions
  add column if not exists requirement_id uuid references requirements (id) on delete set null;

create index if not exists exam_questions_requirement_id_idx
  on exam_questions (requirement_id);

-- ============================================================ 022-examen-aftekenen.sql

-- vinkje — van een uitslag naar een aftekening
--
-- Een vraag weet sinds 021 bij welke eis hij hoort. Daarmee is een uitslag meer
-- dan een cijfer: per eis is te zien of de vragen erover goed waren. Deze
-- migratie zet dat om in twee functies voor de beheerpagina.
--
-- Wat dit met opzet níét doet: automatisch aftekenen. De instructeur kiest welke
-- eisen hij overneemt en drukt op de knop. Een fout in een vraag hoort niet
-- vanzelf in iemands vorderingenstaat te belanden, en "acht van de tien goed"
-- is geen oordeel over welke acht.
--
-- Draai na 021-examenvraag-bij-eis.sql.

-- Per eis: hoeveel vragen erover gingen, hoeveel er goed waren, en of de
-- gekoppelde vaarder een lopende opleiding heeft waar die eis in zit.
create or replace function exam_attempt_requirements (p_attempt uuid)
  returns table (
    requirement_id uuid,
    eis_position   int,
    eis_title      text,
    diploma_id     uuid,
    diploma_name   text,
    vragen         int,
    goed           int,
    enrollment_id  uuid,
    huidige_status text
  )
  language plpgsql stable security definer set search_path = public as $fn$
declare
  gid uuid;
  wie uuid;
begin
  select exam_session_group(a.session_id), a.profile_id into gid, wie
  from exam_attempts a where a.id = p_attempt;

  if gid is null or not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen dit bekijken';
  end if;

  return query
  select
    r.id, r.position, r.title, d.id, d.name,
    count(q.id)::int,
    count(*) filter (where ant.correct)::int,
    e.id,
    s.status::text
  from exam_questions q
  join exam_sessions ses on ses.exam_id = q.exam_id
  join requirements r on r.id = q.requirement_id
  join diplomas d on d.id = r.diploma_id
  left join exam_answers ant on ant.question_id = q.id and ant.attempt_id = p_attempt
  -- De opleiding van déze vaarder in déze groep; zonder koppeling is er niets
  -- om op af te tekenen, en dat mag je zien in plaats van dat het stil misgaat.
  left join enrollments e
    on e.diploma_id = d.id and e.group_id = gid and e.profile_id = wie
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where ses.id = (select session_id from exam_attempts where id = p_attempt)
  group by r.id, r.position, r.title, d.id, d.name, e.id, s.status
  order by d.name, r.position;
end;
$fn$;

-- De knop zelf: zet de gekozen eisen op een stand, met een notitie die zegt
-- waar hij vandaan komt. Wie later naar de aftekenlijst kijkt, leest dus niet
-- alleen dát het gehaald is maar ook waardoor.
create or replace function exam_sign_off_from_attempt (
  p_attempt      uuid,
  p_requirements uuid[],
  p_status       sign_off_status default 'gehaald'
)
  returns int language plpgsql security definer set search_path = public as $fn$
declare
  gid    uuid;
  wie    uuid;
  titel  text;
  dag    date;
  r      record;
  gedaan int := 0;
begin
  select exam_session_group(a.session_id), a.profile_id, e.title, a.submitted_at::date
  into gid, wie, titel, dag
  from exam_attempts a
  join exam_sessions s on s.id = a.session_id
  join exams e on e.id = s.exam_id
  where a.id = p_attempt;

  if gid is null or not is_staff(gid) then
    raise exception 'Alleen instructeurs en beheerders van deze groep kunnen aftekenen';
  end if;
  if wie is null then
    raise exception 'Koppel deze deelname eerst aan een vaarder';
  end if;

  for r in
    select er.requirement_id, er.enrollment_id
    from exam_attempt_requirements(p_attempt) er
    where er.requirement_id = any (p_requirements)
  loop
    if r.enrollment_id is null then
      raise exception 'Deze vaarder werkt niet aan het diploma waar die eis bij hoort';
    end if;

    perform set_sign_off_status(
      r.enrollment_id, r.requirement_id, p_status,
      format('Examen %s, %s', coalesce(titel, 'onbekend'), coalesce(dag::text, 'zonder datum'))
    );
    gedaan := gedaan + 1;
  end loop;

  return gedaan;
end;
$fn$;

-- ============================================================ 023-examen-afbeeldingen.sql

-- vinkje — plaatjes bij een examenvraag
--
-- Een verkeersteken, een knoop, een situatie op het water: sommige vragen zijn
-- zonder plaatje niet te stellen. De bestanden zelf horen niet in de database
-- maar in de opslag van Supabase; `exam_questions.image_path` wijst ernaar.
--
-- De map is openbaar leesbaar, en dat is een keuze: de deelnemer heeft geen
-- account, dus er is niemand om een afgeschermde link aan te geven. Wat erin
-- staat zijn plaatjes bij een vraag — geen gegevens over een persoon. Het juiste
-- antwoord staat er niet in, dus wie een plaatje vindt, weet nog niets.
--
-- Uploaden mag alleen een instructeur of beheerder. Dat is strenger dan lezen,
-- want een open uploadmap is een gratis bestandsserver voor de hele wereld.
--
-- Draai na 022-examen-aftekenen.sql.

create or replace function is_any_staff ()
  returns boolean language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from memberships
    where profile_id = auth.uid() and role in ('instructeur', 'beheerder')
  );
$fn$;

-- De opslag bestaat alleen op een echt Supabase-project. In de tests draait
-- Postgres zonder dat schema, en dan slaat dit blok zichzelf over.
do $$
begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'Geen storage-schema: opslagregels overgeslagen (dat hoort zo buiten Supabase).';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('examen', 'examen', true, 5242880,
          array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
  on conflict (id) do update
    set public = true,
        file_size_limit = 5242880,
        allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp', 'image/gif'];

  execute $p$ drop policy if exists examen_lezen on storage.objects $p$;
  execute $p$
    create policy examen_lezen on storage.objects
      for select using (bucket_id = 'examen')
  $p$;

  execute $p$ drop policy if exists examen_schrijven on storage.objects $p$;
  execute $p$
    create policy examen_schrijven on storage.objects
      for insert to authenticated
      with check (bucket_id = 'examen' and is_any_staff())
  $p$;

  execute $p$ drop policy if exists examen_vervangen on storage.objects $p$;
  execute $p$
    create policy examen_vervangen on storage.objects
      for update to authenticated
      using (bucket_id = 'examen' and is_any_staff())
      with check (bucket_id = 'examen' and is_any_staff())
  $p$;

  execute $p$ drop policy if exists examen_weghalen on storage.objects $p$;
  execute $p$
    create policy examen_weghalen on storage.objects
      for delete to authenticated
      using (bucket_id = 'examen' and is_any_staff())
  $p$;
end;
$$;

-- ============================================================ 024-examen-geslaagd.sql

-- vinkje — in het overzicht zien wie geslaagd is
--
-- Het overzicht van een sessie gaf de score ("25 van 35") maar niet of dat
-- genoeg was. Die grens staat per examen vastgelegd (exams.pass_percent, bij de
-- CWO-examens 71%), dus dat hoort de database erbij te zeggen in plaats van dat
-- iedereen het zelf uitrekent terwijl er twintig mensen klaar zijn.
--
-- De uitkomst is bewust een percentage én een ja/nee: het percentage om te zien
-- hoe ruim iemand het haalde, het ja/nee om er niet over te hoeven twijfelen.
--
-- Draai na 023-examen-afbeeldingen.sql.

drop function if exists exam_session_overview (uuid);

create or replace function exam_session_overview (p_session uuid)
  returns table (
    attempt_id   uuid,
    display_name text,
    profile_id   uuid,
    started_at   timestamptz,
    submitted_at timestamptz,
    beantwoord   int,
    vragen       int,
    score        int,
    total        int,
    percent      int,
    grens        int,
    geslaagd     boolean
  )
  language sql stable security definer set search_path = public as $fn$
  select
    a.id, a.display_name, a.profile_id, a.started_at, a.submitted_at,
    (select count(*)::int from exam_answers x where x.attempt_id = a.id and x.option_id is not null),
    (select count(*)::int from exam_questions q where q.exam_id = e.id),
    a.score, a.total,
    case when coalesce(a.total, 0) > 0
      then round(a.score * 100.0 / a.total)::int end,
    e.pass_percent,
    -- Niet ingeleverd is niet gezakt: dan is er nog niets te zeggen.
    case when a.submitted_at is null then null
         when coalesce(a.total, 0) = 0 then false
         else (a.score * 100.0 / a.total) >= e.pass_percent end
  from exam_attempts a
  join exam_sessions s on s.id = a.session_id
  join exams e on e.id = s.exam_id
  where a.session_id = p_session
    and is_staff(s.group_id)
  order by a.started_at;
$fn$;

-- ============================================================ 025-examen-opruimen.sql

-- vinkje — examenantwoorden opruimen
--
-- Het privacybeleid belooft dat de gegeven antwoorden na afloop van het seizoen
-- weggaan en dat alleen de uitslag blijft. Een belofte die niemand uitvoert is
-- geen belofte, dus hier staan de twee functies achter die knop.
--
-- Wat blijft staan: de deelname zelf — naam, score, of het gehaald is, wanneer
-- het was. Dat hoort bij de opleiding van die vaarder. Wat weggaat zijn de
-- losse antwoorden per vraag; daarmee verdwijnt ook de mogelijkheid om nog eens
-- na te kijken wat iemand precies aankruiste.
--
-- Wissen mag alleen een beheerder. Een instructeur mag alles zien, maar dit is
-- onomkeerbaar en raakt iedereen in de groep tegelijk.
--
-- Draai na 024-examen-geslaagd.sql.

-- Eerst kijken wat het zou opruimen. Niemand wist graag iets waarvan hij het
-- aantal niet kent.
create or replace function exam_cleanup_preview (p_group uuid, p_voor date)
  returns table (sessies int, deelnames int, antwoorden int)
  language sql stable security definer set search_path = public as $fn$
  select
    count(distinct s.id)::int,
    count(distinct a.id)::int,
    count(x.*)::int
  from exam_sessions s
  join exam_attempts a on a.session_id = s.id
  left join exam_answers x on x.attempt_id = a.id
  where s.group_id = p_group
    and s.opened_at::date < p_voor
    and is_staff(p_group);
$fn$;

create or replace function exam_cleanup (p_group uuid, p_voor date)
  returns int language plpgsql security definer set search_path = public as $fn$
declare
  weg int;
begin
  if not is_admin(p_group) then
    raise exception 'Alleen een beheerder kan examenantwoorden wissen';
  end if;
  if p_voor is null then
    raise exception 'Kies tot wanneer er opgeruimd moet worden';
  end if;

  delete from exam_answers x
  using exam_attempts a, exam_sessions s
  where x.attempt_id = a.id
    and a.session_id = s.id
    and s.group_id = p_group
    and s.opened_at::date < p_voor;

  get diagnostics weg = row_count;
  return weg;
end;
$fn$;

-- ============================================================ 026-voortgang.sql

-- vinkje — de voortgang van de hele groep in één keer
--
-- Tot nu toe kon je de stand alleen per persoon opvragen: member_enrollments
-- staat op de eigen profile_id en enrollment_sheet op één inschrijving. Goed
-- voor de app, waar je naar één vaarder kijkt. Onbruikbaar voor de vraag die
-- een instructeur op de steiger stelt: wie moet er nog wat, en wat gaan we
-- vanmiddag doen.
--
-- Twee functies, en ze geven hetzelfde antwoord van twee kanten:
--
--   group_progress   per inschrijving één regel — wie, welk diploma, hoe ver.
--                    Dit is de lijst waarin je iemand zoekt.
--   diploma_eis_stand per eis per lid de stand. Dit is het raster waarin je
--                    ziet dat tien van de twaalf mensen dezelfde eis nog
--                    missen, en dus weet wat je vanmiddag op het water doet.
--
-- Beide zijn alleen voor instructeurs en beheerders. Ze geven de stand van
-- iedereen in de groep, en dat is precies wat een lid niet van zijn
-- medevaarders hoort te zien. Daarom een harde controle vooraf en niet alleen
-- een filter in de where: een filter dat stilletjes niets teruggeeft lijkt op
-- een lege groep, en dan ga je zoeken in de verkeerde hoek.

create or replace function group_progress (p_group uuid)
  returns table (
    enrollment_id    uuid,
    profile_id       uuid,
    full_name        text,
    diploma_id       uuid,
    diploma_code     text,
    diploma_name     text,
    level_label      text,
    discipline_code  text,
    discipline_name  text,
    started_on       date,
    theory_passed_on date,
    awarded_on       date,
    praktijk_total   bigint,
    praktijk_done    bigint,
    theorie_total    bigint,
    theorie_done     bigint,
    onderweg         bigint,
    laatst_afgetekend timestamptz
  )
  language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders zien de voortgang van de hele groep';
  end if;

  return query
  select
    e.id, e.profile_id, p.full_name,
    d.id, d.code, d.name, d.level_label,
    disc.code, disc.name,
    e.started_on, e.theory_passed_on, e.awarded_on,
    -- Alleen eisen, geen onderdelen: die hangen eronder en zijn geen eigen eis.
    count(r.id) filter (where r.kind = 'praktijk'),
    count(s.id) filter (where r.kind = 'praktijk' and s.status = 'gehaald'),
    count(r.id) filter (where r.kind = 'theorie'),
    count(s.id) filter (where r.kind = 'theorie' and s.status = 'gehaald'),
    -- Behandeld maar nog niet gehaald. Telt niet mee in de voortgang, maar je
    -- wil het zien: hier is iemand mee bezig, dus hier valt winst te halen.
    count(s.id) filter (where s.status = 'behandeld'),
    max(s.signed_at) filter (where s.status = 'gehaald')
  from enrollments e
  join profiles p on p.id = e.profile_id
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  join requirements r on r.diploma_id = d.id and r.parent_id is null
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
  group by e.id, p.full_name, d.id, disc.id
  order by p.full_name, disc.sort_order, d.sort_order;
end;
$fn$;

-- Het raster. Eén regel per eis per ingeschreven lid, met de stand erbij.
--
-- Null in `status` is "niet behandeld" — er is dan geen rij in sign_offs. Dat
-- is met opzet een cross join: zou je alleen de bestaande aftekeningen
-- teruggeven, dan kon de pagina niet onderscheiden tussen "deze eis is nog
-- niet behandeld" en "dit lid doet dit diploma niet". Juist die eerste groep is
-- waar het hier om gaat.
create or replace function diploma_eis_stand (p_group uuid, p_diploma uuid)
  returns table (
    enrollment_id uuid,
    profile_id    uuid,
    full_name     text,
    requirement_id uuid,
    kind          requirement_kind,
    positie       int,
    title         text,
    status        sign_off_status
  )
  language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders zien de voortgang van de hele groep';
  end if;

  return query
  select
    e.id, e.profile_id, p.full_name,
    r.id, r.kind, r.position, r.title, s.status
  from enrollments e
  join profiles p on p.id = e.profile_id
  join requirements r on r.diploma_id = e.diploma_id and r.parent_id is null
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
    and e.diploma_id = p_diploma
  order by r.kind, r.position, p.full_name;
end;
$fn$;

-- ============================================================ 027-oud-lid.sql

-- vinkje — wat er gebeurt met de vorderingen van iemand die van de groep af is
--
-- Het bewaren zelf is met opzet en staat zo in het privacybeleid: "Gaat iemand
-- van de groep af, dan blijft zijn voortgang bewaard, zodat hij bij terugkeer
-- kan verdergaan waar hij was. Na 2 jaar zonder lidmaatschap verwijderen we
-- zijn gegevens." Een seizoen overslaan en terugkomen hoort niet te betekenen
-- dat je opnieuw begint.
--
-- Maar er zaten twee gaten tussen die belofte en wat de database deed.
--
-- 1. Bewaard was ook zichtbaar. group_progress en diploma_eis_stand lezen uit
--    enrollments en keken niet naar memberships, terwijl group_members dat wel
--    doet. Iemand die uit de groep gehaald was, verdween dus uit de ledenlijst
--    maar bleef in het voortgangsoverzicht staan — inclusief in "wie moet wat
--    nog doen", waar je een middag op het water mee plant. Dat is hieronder
--    rechtgezet met een join op memberships.
--
-- 2. Die 2 jaar werd door niets waargemaakt. Er was geen moment waarop iemand
--    de groep verliet dat ergens vastgelegd werd, dus de termijn was niet eens
--    te meten. Daar is group_departures voor, en twee functies om het te zien
--    en op te ruimen. Handmatig, net als exam_cleanup: wissen is onomkeerbaar
--    en hoort een besluit van een beheerder te zijn, geen bijwerking van een
--    achtergrondtaak die niemand ziet draaien.
--
-- Draai na 026-voortgang.sql.

-- ------------------------------------------------- wanneer ging iemand eraf

create table if not exists group_departures (
  group_id   uuid not null references groups (id) on delete cascade,
  profile_id uuid not null references profiles (id) on delete cascade,
  left_at    timestamptz not null default now(),
  primary key (group_id, profile_id)
);

alter table group_departures enable row level security;

-- Geen policies: er is geen enkele reden om hier rechtstreeks bij te kunnen.
-- Alles loopt via de functies hieronder, en die controleren zelf de rol.

-- Wie al weg was voordat dit bestond, heeft geen vertrekdatum. De klok begint
-- dan vandaag. Dat is de voorzichtige kant op: liever iets te lang bewaren dan
-- iemand wissen van wie we niet weten wanneer hij wegging.
insert into group_departures (group_id, profile_id)
select distinct e.group_id, e.profile_id
from enrollments e
where not exists (
  select 1 from memberships m
  where m.group_id = e.group_id and m.profile_id = e.profile_id
)
on conflict do nothing;

-- ------------------------------------------------------------ bijhouden

create or replace function noteer_vertrek ()
  returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  -- Een lidmaatschap verdwijnt ook als de persoon of de groep zelf verdwijnt:
  -- delete_my_account() wist het profiel en de cascade neemt het lidmaatschap
  -- mee. Dan is de ouderrij hier al weg en zou deze insert op de foreign key
  -- stuklopen -- en een vertrekdatum bijhouden van iemand die gewist wordt is
  -- sowieso zinloos. Alleen echt vertrek uit een bestaande groep telt.
  if not exists (select 1 from profiles where id = old.profile_id)
     or not exists (select 1 from groups where id = old.group_id) then
    return old;
  end if;

  insert into group_departures (group_id, profile_id)
  values (old.group_id, old.profile_id)
  on conflict (group_id, profile_id) do update set left_at = now();
  return old;
end;
$fn$;

drop trigger if exists memberships_vertrek on memberships;
create trigger memberships_vertrek
  after delete on memberships
  for each row execute function noteer_vertrek();

-- Komt hij terug, dan telt de termijn niet meer. Een trigger en niet een regel
-- in redeem_invite, want lid worden kan ook via create_group en add_member; op
-- de tabel zelf is er maar één plek die het kan missen.
create or replace function wis_vertrek ()
  returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  delete from group_departures
  where group_id = new.group_id and profile_id = new.profile_id;
  return new;
end;
$fn$;

drop trigger if exists memberships_terug on memberships;
create trigger memberships_terug
  after insert on memberships
  for each row execute function wis_vertrek();

-- --------------------------------------------- het overzicht alleen van wie er is

create or replace function group_progress (p_group uuid)
  returns table (
    enrollment_id    uuid,
    profile_id       uuid,
    full_name        text,
    diploma_id       uuid,
    diploma_code     text,
    diploma_name     text,
    level_label      text,
    discipline_code  text,
    discipline_name  text,
    started_on       date,
    theory_passed_on date,
    awarded_on       date,
    praktijk_total   bigint,
    praktijk_done    bigint,
    theorie_total    bigint,
    theorie_done     bigint,
    onderweg         bigint,
    laatst_afgetekend timestamptz
  )
  language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders zien de voortgang van de hele groep';
  end if;

  return query
  select
    e.id, e.profile_id, p.full_name,
    d.id, d.code, d.name, d.level_label,
    disc.code, disc.name,
    e.started_on, e.theory_passed_on, e.awarded_on,
    count(r.id) filter (where r.kind = 'praktijk'),
    count(s.id) filter (where r.kind = 'praktijk' and s.status = 'gehaald'),
    count(r.id) filter (where r.kind = 'theorie'),
    count(s.id) filter (where r.kind = 'theorie' and s.status = 'gehaald'),
    count(s.id) filter (where s.status = 'behandeld'),
    max(s.signed_at) filter (where s.status = 'gehaald')
  from enrollments e
  -- Deze join is het hele punt van 027: wie niet meer in de groep zit, hoort
  -- hier niet te staan. Zijn vorderingen blijven wel bewaard.
  join memberships m on m.group_id = e.group_id and m.profile_id = e.profile_id
  join profiles p on p.id = e.profile_id
  join diplomas d on d.id = e.diploma_id
  join disciplines disc on disc.id = d.discipline_id
  join requirements r on r.diploma_id = d.id and r.parent_id is null
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
  group by e.id, p.full_name, d.id, disc.id
  order by p.full_name, disc.sort_order, d.sort_order;
end;
$fn$;

create or replace function diploma_eis_stand (p_group uuid, p_diploma uuid)
  returns table (
    enrollment_id uuid,
    profile_id    uuid,
    full_name     text,
    requirement_id uuid,
    kind          requirement_kind,
    positie       int,
    title         text,
    status        sign_off_status
  )
  language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders zien de voortgang van de hele groep';
  end if;

  return query
  select
    e.id, e.profile_id, p.full_name,
    r.id, r.kind, r.position, r.title, s.status
  from enrollments e
  join memberships m on m.group_id = e.group_id and m.profile_id = e.profile_id
  join profiles p on p.id = e.profile_id
  join requirements r on r.diploma_id = e.diploma_id and r.parent_id is null
  left join sign_offs s on s.enrollment_id = e.id and s.requirement_id = r.id
  where e.group_id = p_group
    and e.diploma_id = p_diploma
  order by r.kind, r.position, p.full_name;
end;
$fn$;

-- ------------------------------------------------------- zien en opruimen

-- Bewaren wat niemand kan zien is het slechtste van twee werelden: de gegevens
-- staan er, maar niemand weet het en niemand ruimt ze op. Dit is de lijst.
create or replace function former_members (p_group uuid)
  returns table (
    profile_id   uuid,
    full_name    text,
    left_at      timestamptz,
    opleidingen  bigint,
    aftekeningen bigint,
    over_de_tijd boolean
  )
  language plpgsql stable security definer set search_path = public as $fn$
begin
  if not is_staff(p_group) then
    raise exception 'Alleen instructeurs en beheerders zien dit';
  end if;

  return query
  select
    p.id, p.full_name, v.left_at,
    count(distinct e.id),
    count(s.id),
    v.left_at < now() - interval '2 years'
  from group_departures v
  join profiles p on p.id = v.profile_id
  left join enrollments e on e.group_id = v.group_id and e.profile_id = v.profile_id
  left join sign_offs s on s.enrollment_id = e.id
  where v.group_id = p_group
  group by p.id, p.full_name, v.left_at
  having count(distinct e.id) > 0
  order by v.left_at;
end;
$fn$;

-- Onomkeerbaar, dus alleen een beheerder, en alleen voor iemand die er echt
-- niet meer in zit. Dat laatste is geen beleefdheid maar een slot: zonder die
-- controle is dit een knop die de vorderingen van een gewoon lid wist.
create or replace function delete_member_progress (p_group uuid, p_profile uuid)
  returns int language plpgsql security definer set search_path = public as $fn$
declare
  weg int;
begin
  if not is_admin(p_group) then
    raise exception 'Alleen een beheerder kan vorderingen verwijderen';
  end if;

  if exists (
    select 1 from memberships
    where group_id = p_group and profile_id = p_profile
  ) then
    raise exception 'Deze persoon zit nog in de groep. Haal hem er eerst uit.';
  end if;

  -- sign_offs hangen met een cascade aan enrollments, dus die gaan mee.
  delete from enrollments where group_id = p_group and profile_id = p_profile;
  get diagnostics weg = row_count;

  delete from group_departures where group_id = p_group and profile_id = p_profile;

  -- Is er daarna niets meer van deze persoon over, dan is de naam het laatste
  -- stukje persoonsgegeven dat nog ergens staat. Dat hoort ook weg -- maar
  -- alleen bij iemand zonder account; wie kan inloggen, verwijdert zichzelf
  -- via Meer > Mijn gegevens, en dat is niet aan een beheerder van één groep.
  if not exists (select 1 from memberships where profile_id = p_profile)
     and not exists (select 1 from enrollments where profile_id = p_profile)
     and not exists (select 1 from auth.users u where u.id = p_profile)
  then
    delete from profiles where id = p_profile;
  end if;

  return weg;
end;
$fn$;

-- ============================================================ 028-lesmateriaal.sql

-- vinkje — lesmateriaal van de groep bij een diploma
--
-- Een lesboek, een naslagkaart, een eigen uitleg: dingen die een vaarder erbij
-- wil hebben als hij voor een diploma leert. Het bestand gaat in de opslag van
-- Supabase, de regel in deze tabel wijst ernaar.
--
-- Twee dingen anders dan bij de examenplaatjes in 023, allebei met reden.
--
-- 1. De map is NIET openbaar. Bij een examenplaatje kon dat: de deelnemer heeft
--    geen account, dus er is niemand om een afgeschermde link aan te geven, en
--    een plaatje van een verkeersteken is van niemand. Lesmateriaal is dat wel.
--    Het is vaak gemaakt door iemand anders -- een andere Scoutinggroep, een
--    uitgever -- en dan is "iedereen met de link" niet goed genoeg. Lezen gaat
--    daarom via een ondertekende link die verloopt, en die krijg je alleen als
--    je in de groep zit.
--
-- 2. Het hangt aan een groep, niet aan de landelijke catalogus. Elke groep zet
--    er zijn eigen spullen in en ziet die van een ander niet. Dat is ook de
--    reden dat dit zo gebouwd is: wie materiaal van iemand anders wil delen,
--    regelt toestemming voor zijn eigen groep en zet het in zijn eigen map,
--    zonder dat het meteen in de app van heel varend Scouting staat.
--
-- Lezen mag elk lid van de groep, dus ook een vaarder zonder instructeursrol --
-- dat is het punt van lesmateriaal. Toevoegen en weggooien is voor
-- instructeurs en beheerders.
--
-- Draai na 027-oud-lid.sql.

create table if not exists materials (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references groups (id) on delete cascade,
  -- Null is "hoort bij geen enkel diploma in het bijzonder": een algemene
  -- naslagkaart, de regels van de vereniging. Gaat een eigen lijst weg, dan
  -- blijft het materiaal bestaan en wordt het algemeen; weggooien van een
  -- diploma hoort geen bestand mee te nemen.
  diploma_id  uuid references diplomas (id) on delete set null,
  title       text not null,
  -- Waar het bestand staat: <group_id>/<uuid>.pdf. De groep staat vooraan
  -- omdat de opslagregels daarop kijken -- die kennen deze tabel niet.
  path        text not null unique,
  bytes       bigint,
  uploaded_by uuid references profiles (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);

create index if not exists materials_group_idx on materials (group_id);
create index if not exists materials_diploma_idx on materials (diploma_id);

alter table materials enable row level security;

drop policy if exists materials_lezen on materials;
create policy materials_lezen on materials
  for select using (is_member(group_id));

drop policy if exists materials_toevoegen on materials;
create policy materials_toevoegen on materials
  for insert with check (is_staff(group_id));

drop policy if exists materials_bijwerken on materials;
create policy materials_bijwerken on materials
  for update using (is_staff(group_id)) with check (is_staff(group_id));

drop policy if exists materials_weghalen on materials;
create policy materials_weghalen on materials
  for delete using (is_staff(group_id));

-- ------------------------------------------------------------- de opslag
--
-- De opslag bestaat alleen op een echt Supabase-project. In de tests draait
-- Postgres zonder dat schema, en dan slaat dit blok zichzelf over.

do $$
begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'Geen storage-schema: opslagregels overgeslagen (dat hoort zo buiten Supabase).';
    return;
  end if;

  -- public = false. Dat is het hele verschil met de examenmap: zonder
  -- ondertekende link kom je er niet in, ook niet als je het pad raadt.
  -- 25 MB, want een gescand lesboek is zo tien.
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('lesmateriaal', 'lesmateriaal', false, 26214400,
          array['application/pdf', 'image/png', 'image/jpeg'])
  on conflict (id) do update
    set public = false,
        file_size_limit = 26214400,
        allowed_mime_types = array['application/pdf', 'image/png', 'image/jpeg'];

  -- De groep staat vooraan in het pad. De regex is geen franje: zonder die
  -- controle laat een bestand met een naam als "hallo/x.pdf" de cast naar uuid
  -- klappen, en dan faalt de policy met een foutmelding in plaats van netjes
  -- nee te zeggen.
  execute $p$ drop policy if exists lesmateriaal_lezen on storage.objects $p$;
  execute $p$
    create policy lesmateriaal_lezen on storage.objects
      for select to authenticated
      using (
        bucket_id = 'lesmateriaal'
        and name ~ '^[0-9a-fA-F-]{36}/'
        and is_member(split_part(name, '/', 1)::uuid)
      )
  $p$;

  execute $p$ drop policy if exists lesmateriaal_schrijven on storage.objects $p$;
  execute $p$
    create policy lesmateriaal_schrijven on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'lesmateriaal'
        and name ~ '^[0-9a-fA-F-]{36}/'
        and is_staff(split_part(name, '/', 1)::uuid)
      )
  $p$;

  execute $p$ drop policy if exists lesmateriaal_vervangen on storage.objects $p$;
  execute $p$
    create policy lesmateriaal_vervangen on storage.objects
      for update to authenticated
      using (
        bucket_id = 'lesmateriaal'
        and name ~ '^[0-9a-fA-F-]{36}/'
        and is_staff(split_part(name, '/', 1)::uuid)
      )
      with check (
        bucket_id = 'lesmateriaal'
        and name ~ '^[0-9a-fA-F-]{36}/'
        and is_staff(split_part(name, '/', 1)::uuid)
      )
  $p$;

  execute $p$ drop policy if exists lesmateriaal_weghalen on storage.objects $p$;
  execute $p$
    create policy lesmateriaal_weghalen on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'lesmateriaal'
        and name ~ '^[0-9a-fA-F-]{36}/'
        and is_staff(split_part(name, '/', 1)::uuid)
      )
  $p$;
end;
$$;

-- ============================================================ 010-eisen.sql

-- vinkje — de diploma's en hun eisen
--
-- This file is the catalogue. It is written to be run again, as often as you
-- like: every row upserts on its `code`, so ids stay the same and aftekeningen
-- that already exist keep pointing at the same eis. That is what makes it safe
-- to correct a typo, sharpen a toelichting or add a diploma and re-run the
-- whole file against a database that is already in use.
--
-- Source per diploma is in the `source` column and in docs/EISEN.md. Where the
-- handboek is ambiguous the list here is deliberately the longer one: an eis
-- too many is visible on screen and can be deleted, an eis that is missing is
-- invisible and gets forgotten.
--
-- Strings are dollar-quoted ($$...$$) throughout, so an apostrophe in
-- "Roeicommando's" needs no escaping and cannot silently break the file.
--
-- Run after 003-rpc.sql.

-- ---------------------------------------------------------------- disciplines

insert into disciplines (code, name, subtitle, sort_order) values
  ('roeien',   $$Roeien$$,            $$Roeivlet$$,               1),
  ('kielboot', $$Zeilen$$,            $$Kielboot$$,               2),
  ('bbm',      $$Buitenboordmotor$$,  $$Boot met buitenboordmotor$$, 3),
  ('sloep',    $$Sloep en motorvlet$$, $$Motorvaren$$,            4)
on conflict (code) do update set
  name       = excluded.name,
  subtitle   = excluded.subtitle,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------- diploma's

insert into diplomas (discipline_id, code, name, level_label, summary, sort_order, source)
select d.id, v.code, v.name, v.level_label, v.summary, v.sort_order, v.source
from (values
  ('roeien', 'roeien-12', $$Roeien I/II$$, $$I/II$$,
   $$Voor wie onder niet te moeilijke omstandigheden op meren en plassen kan varen in een roeivlet: niet te druk vaarwater, overdag, met voldoende zicht.$$,
   1, $$Handboek Opleidingen deel 3.2 Roeien (2015), §3.2.4$$),

  ('roeien', 'roeien-3', $$Roeien III$$, $$III$$,
   $$Voor wie het commando kan voeren over een roeivlet met een groep roeiers, op meren, plassen en kanalen tot en met windkracht 5 Beaufort.$$,
   2, $$Handboek Opleidingen deel 3.2 Roeien (2015), §3.2.5$$),

  ('kielboot', 'kielboot-1', $$Kielboot I$$, $$I$$,
   $$Voor wie onder gunstige omstandigheden kan zeilen: rustig vaarwater en matige wind tot en met 3 Beaufort, in een boot van minstens 200 kg met maximaal 20 m² zeil.$$,
   1, $$Handboek Opleidingen deel 3.1 Kielboot (2015), §3.1.4$$),

  ('kielboot', 'kielboot-2', $$Kielboot II$$, $$II$$,
   $$Voor wie onder niet te moeilijke omstandigheden op meren en plassen kan zeilen, overdag en met voldoende zicht, tot en met windkracht 4 Beaufort.$$,
   2, $$Handboek Opleidingen deel 3.1 Kielboot (2015), §3.1.5$$),

  ('kielboot', 'kielboot-3', $$Kielboot III$$, $$III$$,
   $$Voor wie tot en met windkracht 6 zelfstandig kan varen op meren, plassen en kanalen, in een boot van minstens 200 kg met maximaal 30 m² zeil.$$,
   3, $$Handboek Opleidingen deel 3.1 Kielboot (2015), §3.1.6$$),

  ('kielboot', 'kielboot-4', $$Kielboot IV$$, $$IV$$,
   $$Voor wie onder alle omstandigheden kan varen. Alleen te halen met een examen onder toezicht van een erkend examinator, bij 7 tot 25 knopen wind. Gelijk aan het eigenvaardigheidsniveau van de Zeilinstructeur 3-opleiding.$$,
   4, $$Handboek Opleidingen deel 3.1 Kielboot (2015), §3.1.7$$),

  ('bbm', 'bbm-12', $$Buitenboordmotor I/II$$, $$I/II$$,
   $$Voor wie onder eenvoudige omstandigheden met een buitenboordmotor vaart: tot en met windkracht 3 Beaufort, bij daglicht, op meren en kanalen.$$,
   1, $$Handboek Opleidingen deel 3.3 Buitenboordmotor (2015), §3.3.4$$),

  ('bbm', 'bbm-3', $$Buitenboordmotor III$$, $$III$$,
   $$Voor wie tot en met windkracht 5 Beaufort zelfstandig vaart op meren en kanalen, vaarwater klasse 1 t/m 4.$$,
   2, $$Handboek Opleidingen deel 3.3 Buitenboordmotor (2015), §3.3.5$$),

  ('sloep', 'sloep-1', $$Bemanningslid$$, $$CWO I$$,
   $$Vanaf 12 jaar. Kan onder verantwoordelijkheid van de schipper als bemanningslid op een sloep of motorvlet meedraaien.$$,
   1, $$Handboek Opleidingen deel 3.4 Motorboot / Sloep- en motorvletvaren (2020), §2.1 en §4.1$$),

  ('sloep', 'sloep-2', $$Dagschipper$$, $$CWO II$$,
   $$Vanaf 16 jaar. Vaart, manoeuvreert en navigeert zelfstandig bij daglicht tot windkracht 4, en geeft daarbij leiding aan de bemanning.$$,
   2, $$Handboek Opleidingen deel 3.4 Motorboot / Sloep- en motorvletvaren (2020), §2.2 en §4.1$$),

  ('sloep', 'sloep-3', $$Schipper$$, $$CWO III$$,
   $$Vanaf 18 jaar. Vaart zelfstandig bij dag en nacht tot windkracht 6 en geeft onder alle omstandigheden leiding aan de bemanning. Eigenvaardigheidsniveau van Instructeur I-2.$$,
   3, $$Handboek Opleidingen deel 3.4 Motorboot / Sloep- en motorvletvaren (2020), §2.3 en §4.1$$),

  ('sloep', 'sloep-4', $$All Round Schipper$$, $$CWO IV$$,
   $$Vanaf 18 jaar. Draagt de eindverantwoordelijkheid voor bemanning en schip op meerdaagse tochten naar onbekende bestemmingen. Instapeis: een tochtplanning voor een door de examinator opgegeven tocht.$$,
   4, $$Handboek Opleidingen deel 3.4 Motorboot / Sloep- en motorvletvaren (2020), §2.4 en §4.1$$)
) as v(discipline, code, name, level_label, summary, sort_order, source)
join disciplines d on d.code = v.discipline
on conflict (code) do update set
  discipline_id = excluded.discipline_id,
  name          = excluded.name,
  level_label   = excluded.level_label,
  summary       = excluded.summary,
  sort_order    = excluded.sort_order,
  source        = excluded.source;

-- ---------------------------------------------------------------- de eisen
--
-- `position` is the number the eis carries in the handboek, so the lijst on
-- screen and het boekje in de hand tellen gelijk op.

insert into requirements (diploma_id, code, kind, position, title, detail)
select dp.id, v.code, v.kind::requirement_kind, v.position, v.title, v.detail
from (values

-- ---------------- Roeien I/II — praktijk
('roeien-12', 'roeien-12.p1',  'praktijk', 1, $$Het schip vaarklaar en nachtklaar maken$$,
 $$Inventaris controleren, schip schoon en droog maken. Riemen juist neerleggen: blad naar de boeg, wrikriem aan stuurboord met het blad naar de spiegel. Controleren op lek- en regenwater. Voor iedere opvarende een reddingvest aan boord, bij voorkeur aangetrokken.$$),
('roeien-12', 'roeien-12.p2',  'praktijk', 2, $$Verhalen van het schip$$,
 $$Zonder motor. Alle manieren op spierkracht mogen, zolang het geen gevaar oplevert voor bemanning, materiaal of andere scheepvaart. Op het schip zelf zo veel mogelijk vanuit de kuip werken.$$),
('roeien-12', 'roeien-12.p3',  'praktijk', 3, $$Roeicommando's uitvoeren$$,
 $$Op bevel van de schipper kunnen uitvoeren: dollen in; los voor en los achter; op riemen; haalt op gelijk; stopt af; strijkt gelijk; zet af; riemen lopen; riemen geroeid. De commando's kunnen vooraf worden gegaan door 'beide boorden', 'stuurboord' of 'bakboord'.$$),
('roeien-12', 'roeien-12.p4',  'praktijk', 4, $$Aanleg met de punt van het schip$$,
 $$In de wind aanleggen op een vooraf aangewezen punt, met roeicommando's, zó dat het schip zonder noemenswaardige kracht afgehouden kan worden. De instructeur mag aanwijzingen geven om het veilig te laten verlopen.$$),
('roeien-12', 'roeien-12.p5',  'praktijk', 5, $$Een acht varen$$,
 $$Zonder noemenswaardig roergebruik: twee rondjes in tegengestelde richting. De bochten worden gemaakt door de ene boord te laten halen en de andere te laten strijken.$$),
('roeien-12', 'roeien-12.p6',  'praktijk', 6, $$Jagen$$,
 $$Met een aantal mensen het schip aan een lijn vooruittrekken. De lijn vlak bij het draaipunt vastmaken, zodat de boeg niet naar de kant wordt getrokken, lang genoeg, en met gebruik van de driftbeperkende middelen. Let op de natuur en andermans spullen.$$),
('roeien-12', 'roeien-12.p7',  'praktijk', 7, $$Wrikken$$,
 $$Met één riem in het wrikgat het schip in een rechte lijn voortbewegen.$$),
('roeien-12', 'roeien-12.p8',  'praktijk', 8, $$Het schip afmeren$$,
 $$Zo vastleggen dat ook op lange termijn geen schade aan eigen of andere schepen mogelijk is. Zo min mogelijk lijnen naar de wal (minder dan 3 of meer dan 6 is altijd fout), zo lang mogelijk gekozen. Eerst de lijnen die de natuurlijke beweging van het schip tegengaan.$$),
('roeien-12', 'roeien-12.p9',  'praktijk', 9, $$Toepassing van de reglementen$$,
 $$De uitwijkregels voor het eigen vaargebied toepassen. Een uitwijkmanoeuvre wordt tijdig ingezet. De bemanning mag waarschuwen voor andere scheepvaart.$$),

-- ---------------- Roeien I/II — theorie
('roeien-12', 'roeien-12.t1',  'theorie', 1, $$Schiemanswerk$$,
 $$Bij naam kennen, kunnen leggen en de functie kennen van: twee halve steken (de eerste slippend), achtknoop, platte knoop, mastworp (met slipsteek als borg). Ook: een lijn opschieten en een lijn beleggen op een kikker.$$),
('roeien-12', 'roeien-12.t2',  'theorie', 2, $$Roeitermen$$,
 $$Kunnen aangeven wat bedoeld wordt met: slagroeier, boegroeier, midroeier, roerganger, haakvoor, stuurboord, bakboord, hogerwal, lagerwal, bomen, jagen, wrikken, in de wind, opschieten, beleggen. Plus alle roeicommando's.$$),
('roeien-12', 'roeien-12.t3',  'theorie', 3, $$Onderdelen$$,
 $$Van de eigen boot en tuigage, in de praktijk én op een tekening, minstens 15 onderdelen bij de juiste naam noemen. In ieder geval: boeg, hek, dolboord, doften, roer, helmstok, stuurboord en bakboord, roeiriem, wrikriem.$$),
('roeien-12', 'roeien-12.t4',  'theorie', 4, $$Veiligheid$$,
 $$De eisen kennen die aan een reddingvest gesteld worden. Weten hoe te handelen bij een omgeslagen boot.$$),
('roeien-12', 'roeien-12.t5',  'theorie', 5, $$Reglementen$$,
 $$De genoemde artikelen uit het Binnenvaartpolitiereglement kunnen toepassen: begripsbepalingen 1.01, voorzorgsmaatregelen 1.04, afwijking 1.05, tegengestelde koersen 6.01/6.03/6.04, voorbijlopen 6.10, vertrek 6.14, kruisende koersen 6.17, ligplaats innemen 7.01. Weten dat er naast het BPR andere reglementen gelden en waar die te vinden zijn.$$),
('roeien-12', 'roeien-12.t6',  'theorie', 6, $$Gedragsregels$$,
 $$De goede gebruiken kennen ten opzichte van andere watersporters, waaronder wedstrijdzeilers. De verantwoording kennen ten opzichte van het milieu.$$),
('roeien-12', 'roeien-12.t7',  'theorie', 7, $$Weersinvloeden$$,
 $$Het weerbericht kunnen interpreteren met het oog op de veiligheid en de eigen vaardigheid. Voortekenen van plotselinge weersomslagen, zoals onweer en zware windvlagen, tijdig herkennen.$$),
('roeien-12', 'roeien-12.t8',  'theorie', 8, $$Vaarproblematiek andersoortige schepen$$,
 $$Het gevaar kennen van de dode hoek en van de zuiging van grote schepen. Weten dat grote schepen op smal vaarwater niet kunnen wijken, en dat ook grote vrachtschepen sterk kunnen verlijeren.$$),

-- ---------------- Roeien III — praktijk
('roeien-3', 'roeien-3.p1',  'praktijk',  1, $$Het schip vaarklaar en nachtklaar maken$$,
 $$Inventaris controleren, schip schoon en droog. Riemen juist neerleggen: blad naar de boeg, wrikriem aan stuurboord met het blad naar de spiegel. Dollen uit de dolpotten, zwaard op, anker geborgd. Controleren op lek- en regenwater, en voor iedere opvarende een reddingvest aan boord.$$),
('roeien-3', 'roeien-3.p2',  'praktijk',  2, $$Verhalen van het schip$$,
 $$Over kleine afstanden, zonder motor én zonder roeiriemen. Het mag geen gevaar opleveren voor bemanning, materiaal of andere scheepvaart; op het schip zelf zo veel mogelijk vanuit de kuip werken.$$),
('roeien-3', 'roeien-3.p3',  'praktijk',  3, $$Roeitechnieken en roeicommando's kunnen uitvoeren$$,
 $$Boven op de commando's van Roeien I/II ook: riemen op, dollen richten, riemen toe, riemen over, stootwillen binnen en buiten. Op bevel van de schipper uitvoeren.$$),
('roeien-3', 'roeien-3.p4',  'praktijk',  4, $$Roeicommando's kunnen geven$$,
 $$Dezelfde commando's zelf op het juiste moment gebruiken, luid en duidelijk, met goed onderscheid tussen bakboord en stuurboord waar de manoeuvre dat vraagt.$$),
('roeien-3', 'roeien-3.p5',  'praktijk',  5, $$Aanleg met de punt van het schip$$,
 $$Met roeicommando's aanleggen op een vooraf aangewezen punt, boeg naar de wal, zó dat het schip zonder noemenswaardige kracht afgehouden kan worden.$$),
('roeien-3', 'roeien-3.p6',  'praktijk',  6, $$Aanleggen met de spiegel van het schip$$,
 $$Zelfde punt, maar met de spiegel naar de wal. Houd rekening met de afstand die je moet strijken, en bedien het roer zoals het bij een achteruitvarend schip hoort.$$),
('roeien-3', 'roeien-3.p7',  'praktijk',  7, $$Zijwaartse aanleg$$,
 $$Met de zijkant langs de wal, op een vooraf aangewezen punt, zonder noemenswaardige kracht af te hoeven houden. Stootwillen worden goed gebruikt.$$),
('roeien-3', 'roeien-3.p8',  'praktijk',  8, $$Een kleine acht varen$$,
 $$Zonder roergebruik, twee rondjes in tegengestelde richting. De bochten door de ene boord te laten halen en de andere te laten strijken of afstoppen — met inzicht in welke bocht welk commando oplevert.$$),
('roeien-3', 'roeien-3.p9',  'praktijk',  9, $$Man over boord manoeuvre$$,
 $$Constateren en roepen, "zwem" toeroepen, zo nodig een drijfmiddel toewerpen en iemand laten wijzen. Ruime bocht, aan de windse koers aankomen, langzaam aan lij langsvaren; riemen lopen aan loef, riemen aan lij in het water. De drenkeling aan loef op het draaipunt zijdelings en zo horizontaal mogelijk binnenhalen. Bij weinig wind kan strijken ook.$$),
('roeien-3', 'roeien-3.p10', 'praktijk', 10, $$Eenvoudig ankeren$$,
 $$Stilliggen bij het uitgooien, geen lijnen om het anker, het anker moet zich kunnen ingraven en het schip blijft nagenoeg in de wind liggen. Strijken tot het anker houdt, en controleren met een achtergrondspeiling.$$),
('roeien-3', 'roeien-3.p11', 'praktijk', 11, $$Roeimanoeuvres zonder roer$$,
 $$Enkele manoeuvres uitvoeren zonder het roer te gebruiken — bijvoorbeeld een kleine of een grote acht.$$),
('roeien-3', 'roeien-3.p12', 'praktijk', 12, $$Jagen$$,
 $$Het schip aan een lijn vooruittrekken, en verschillende manieren van jagen kennen. De lijn lang genoeg, de driftbeperkende middelen in gebruik. Let op de natuur en andermans spullen.$$),
('roeien-3', 'roeien-3.p13', 'praktijk', 13, $$Wrikken$$,
 $$Met één riem in het wrikgat het schip voortbewegen én ermee kunnen manoeuvreren, met aandacht voor de overige scheepvaart.$$),
('roeien-3', 'roeien-3.p14', 'praktijk', 14, $$Het schip afmeren$$,
 $$Zo vastleggen dat ook op lange termijn geen schade aan eigen of andere schepen mogelijk is. Minder dan 3 of meer dan 6 lijnen naar de wal is altijd fout; kies ze zo lang mogelijk en leg eerst de lijnen vast die de natuurlijke beweging van het schip tegengaan.$$),
('roeien-3', 'roeien-3.p15', 'praktijk', 15, $$Aanvarings- en achtergrondpeiling kunnen maken$$,
 $$Bij kruisende koersen vaststellen of er aanvaringsgevaar ontstaat, door over het andere schip een peiling op de achtergrond te nemen.$$),
('roeien-3', 'roeien-3.p16', 'praktijk', 16, $$Toepassing van de reglementen$$,
 $$De uitwijkregels voor het eigen vaargebied toepassen, en een uitwijkmanoeuvre tijdig inzetten.$$),
('roeien-3', 'roeien-3.p17', 'praktijk', 17, $$Terminologie$$,
 $$Zo veel mogelijk de juiste naamgeving gebruiken — binnen de boot én tussen schepen en personen onderling.$$),
('roeien-3', 'roeien-3.p18', 'praktijk', 18, $$Tonen van inzicht, veiligheid$$,
 $$De roerganger heeft kennis van zaken, bereidt zijn manoeuvres voor en stelt ze zo nodig bij. Hij kijkt goed om zich heen en houdt rekening met bemanning en omgeving.$$),
('roeien-3', 'roeien-3.p19', 'praktijk', 19, $$Schiemannen praktijk$$,
 $$Touwwerk vrij van zand en scherpe randen houden. Bij naam kennen, kunnen leggen en de functie kennen van: twee halve steken (de eerste slippend), achtknoop, platte knoop, mastworp (met slipsteek als borg), enkele schootsteek, paalsteek. Plus een lijn opschieten en beleggen op een kikker.$$),

-- ---------------- Roeien III — theorie
('roeien-3', 'roeien-3.t1', 'theorie', 1, $$Schiemanswerk$$,
 $$Dezelfde steken als in de praktijkeis, met hun functie, plus opschieten en beleggen. Ook: touwwerk vrij van zand houden en zo veel mogelijk uit UV-licht, en het begrip schavielen met de maatregelen daartegen kunnen beschrijven.$$),
('roeien-3', 'roeien-3.t2', 'theorie', 2, $$Roeitermen$$,
 $$Weten wat bedoeld wordt met: slagroeier, boegroeier, roerganger, haakvoor, stuurboord, bakboord, hogerwal, lagerwal, loef, lij, bomen, jagen, wrikken, in de wind, opschieten, beleggen. Plus alle commando's, inclusief die voor zwaard en anker.$$),
('roeien-3', 'roeien-3.t3', 'theorie', 3, $$Onderdelen$$,
 $$Van eigen boot en tuigage, in de praktijk en op een tekening, minstens 30 onderdelen bij naam noemen. In ieder geval: boeg, hek, spiegel, dolboord, doften, roer, helmstok, stuur- en bakboord, roeiriem, wrikriem, blad, handvat, dollen, dolpot, landvast, hoosvat.$$),
('roeien-3', 'roeien-3.t4', 'theorie', 4, $$Veiligheid$$,
 $$Weten hoe te handelen bij een omgeslagen boot. De eisen kennen die aan een zwemvest én aan een reddingvest gesteld worden, en weten hoe reddingvest en reddingsboei gebruikt moeten worden.$$),
('roeien-3', 'roeien-3.t5', 'theorie', 5, $$Reglementen$$,
 $$Een flink uitgebreidere lijst uit het Binnenvaartpolitiereglement dan bij Roeien I/II: begripsbepalingen, verplichtingen van de schipper, tekens en lichten van grote en kleine schepen, veerponten en drijvende werktuigen, geluidsseinen, verkeerstekens, de vaarregels, bruggen en sluizen. Ook weten welke andere reglementen in het eigen vaargebied gelden, waar je ze vindt, en dat voor bepaalde schepen een Klein Vaarbewijs verplicht is. De volledige artikelopsomming staat in het handboek.$$),
('roeien-3', 'roeien-3.t6', 'theorie', 6, $$Theorie van het roeien$$,
 $$Theoretische kennis van de verschillende manoeuvres, van de roerwerking achteruit en van de theorie achter het jagen. De functie van het midzwaard kennen, en weten om te gaan met stroom op een rivier.$$),
('roeien-3', 'roeien-3.t7', 'theorie', 7, $$Gedragsregels, vlagvoering en jachtetiquette$$,
 $$De goede gebruiken ten opzichte van andere watersporters kennen, en de verantwoording ten opzichte van het milieu.$$),
('roeien-3', 'roeien-3.t8', 'theorie', 8, $$Weersinvloeden$$,
 $$Het weerbericht kunnen interpreteren met het oog op de veiligheid en de eigen vaardigheid, en voortekenen van plotselinge weersomslagen zoals onweer en zware windvlagen tijdig herkennen.$$),
('roeien-3', 'roeien-3.t9', 'theorie', 9, $$Vaarproblematiek andersoortige schepen$$,
 $$Het gevaar kennen van de dode hoek en van de zuiging van grote schepen. Weten dat grote schepen op smal vaarwater niet kunnen wijken, en dat ook grote vrachtschepen sterk kunnen verlijeren.$$),

-- ---------------- Kielboot I — praktijk
('kielboot-1', 'kielboot-1.p1',  'praktijk',  1, $$Het schip zeilklaar en nachtklaar maken$$,
 $$Zeilklaar: zeilkleden eraf, kraanlijn doorzetten, mik of schaar weg, fok aanslaan, fokkenschoten inscheren, vallen aanslaan, inventaris controleren. Nachtklaar: vallen los en rammelvrij wegwerken, fok in de zak, grootzeil opdoeken, giek en gaffel op de mik, kraanlijn los, zeilkleden erop, inventaris opruimen.$$),
('kielboot-1', 'kielboot-1.p2',  'praktijk',  2, $$Verhalen van het schip$$,
 $$Zonder motor. Alle manieren op spierkracht mogen, zolang het geen gevaar oplevert voor bemanning, materiaal of andere scheepvaart. Op het schip zelf zo veel mogelijk vanuit de kuip werken.$$),
('kielboot-1', 'kielboot-1.p3',  'praktijk',  3, $$Stilliggend hijsen en strijken van de zeilen$$,
 $$Met de kop nagenoeg in de wind, zo nodig eerst verhalen, en iemand zorgt dat het schip niet tegen de wal komt. Grootzeil: schoot los, zeilbandjes los, bij gaffelzeil de gaffel op circa 45 graden, vallen samen, klauwval vast, halstalie vast, piek stellen tot er een plooi van nok naar hals staat. Fok: schoothoek lostrekken, strietsen, val beleggen, vallen en kraanlijn opschieten.$$),
('kielboot-1', 'kielboot-1.p4',  'praktijk',  4, $$Stand en bediening van de zeilen$$,
 $$Op een rechte koers én in de bocht zo veel mogelijk de juiste zeilstand. Zeilen zo ver gevierd als kan zonder dat het voorlijk kilt; bij oploeven mag de fok, bij afvallen het grootzeil bescheiden killen. De zeilen ondersteunen het sturen.$$),
('kielboot-1', 'kielboot-1.p5',  'praktijk',  5, $$Sturen, roer- en schootbediening$$,
 $$Met roer en zeilen een rechte koers en bochten varen, zó dat een aangewezen punt zonder onnodige omwegen wordt aangezeild.$$),
('kielboot-1', 'kielboot-1.p6',  'praktijk',  6, $$Overstag gaan$$,
 $$Van hoog aan de wind over de ene boeg naar hoog aan de wind over de andere. Commando's: "klaar om te wenden" als waarschuwing, "ree" bij de start (fokkenschoot 10 à 15 cm vieren), zo nodig "fok bak", "fok over" zodra de boot door de wind is, "fok aan" als er weer snelheid is. Zo min mogelijk roer; de stuurman gaat met het gezicht naar voren verzitten.$$),
('kielboot-1', 'kielboot-1.p7',  'praktijk',  7, $$Opkruisen in breed vaarwater$$,
 $$Goed hoog aan de wind varen en zo nodig overstag gaan om een in de wind gelegen punt aan te zeilen.$$),
('kielboot-1', 'kielboot-1.p8',  'praktijk',  8, $$Gijpen$$,
 $$Zien aankomen dat er gegijpt moet worden en de bemanning waarschuwen. Het zeil komt pal voor de wind over; na de gijp zit de stuurman aan de hoge zijde en vaart het schip een vloeiende koers. Zeilstand klopt direct voor en na de manoeuvre — vooral het vieren van de schoot moet snel.$$),
('kielboot-1', 'kielboot-1.p9',  'praktijk',  9, $$Afvaren van hogerwal$$,
 $$Kop nagenoeg in de wind, landvasten los, opgeschoten en paraat opgeborgen. Bemanning evenredig over stuurboord en bakboord, stuurman aan de toekomstige loefzijde, schoten goed los. Goed uitkijken, dan afzetten onder een zo groot mogelijke hoek met de wal, of recht achteruit. Zo nodig fok bak; de afduwer gaat aan loef naar de kuip.$$),
('kielboot-1', 'kielboot-1.p10', 'praktijk', 10, $$Onder toezicht aankomen aan hogerwal$$,
 $$In principe aan de wind aankomen; een stukje tegen de wind in opschieten mag. De snelheid wordt met de zeilen geregeld. De instructeur mag aanwijzingen geven om het veilig te laten verlopen.$$),
('kielboot-1', 'kielboot-1.p11', 'praktijk', 11, $$Afmeren op de eigen ligplaats$$,
 $$Het schip op de eigen ligplaats afmeren, stootkussens gebruiken waar beschadiging dreigt, en de juiste knopen en steken gebruiken.$$),
('kielboot-1', 'kielboot-1.p12', 'praktijk', 12, $$De noodzaak van het reven onderkennen$$,
 $$Kunnen aangeven wanneer er gereefd moet worden, op grond van schip, zeilwater, windkracht en de geoefendheid van de bemanning. Het reven zelf hoeft op dit niveau nog niet.$$),
('kielboot-1', 'kielboot-1.p13', 'praktijk', 13, $$Toepassing van de reglementen$$,
 $$De uitwijkregels voor het eigen vaargebied toepassen en een uitwijkmanoeuvre tijdig inzetten. De bemanning mag waarschuwen voor andere scheepvaart.$$),

-- ---------------- Kielboot I — theorie
('kielboot-1', 'kielboot-1.t1', 'theorie', 1, $$Schiemanswerk$$,
 $$Kennen en kunnen leggen: achtknoop, twee halve steken (de eerste slippend), paalsteek, reefsteek (platte knoop), en het beleggen op klamp, nagel of kikker. Ook een tros kunnen opschieten.$$),
('kielboot-1', 'kielboot-1.t2', 'theorie', 2, $$Zeiltermen$$,
 $$Weten wat bedoeld wordt met: hogerwal, lagerwal, bakboord, stuurboord, hoge en lage zijde, loef- en lijzijde, in de wind, aan de wind, halve wind, ruime wind, voor de wind, oploeven, afvallen, overstag gaan, gijpen, kruisrak, killen van het zeil.$$),
('kielboot-1', 'kielboot-1.t3', 'theorie', 3, $$Onderdelen$$,
 $$Van eigen boot en tuigage, in de praktijk en op een tekening, minstens 15 onderdelen bij de juiste naam noemen (naar keuze van de kandidaat).$$),
('kielboot-1', 'kielboot-1.t4', 'theorie', 4, $$Veiligheid$$,
 $$Kunnen uitleggen waarom je bij een omgeslagen boot blijft, en de eisen kennen die aan een reddingvest gesteld worden.$$),
('kielboot-1', 'kielboot-1.t5', 'theorie', 5, $$Reglementen$$,
 $$Uit het Binnenvaartpolitiereglement kunnen toepassen: groot en klein schip (1.01), voorzorgsmaatregelen (1.04), afwijking van het reglement (1.05), tegengestelde koersen met stuurboordwal en voorrang van groot op klein (6.04), en kruisende koersen inclusief kleine zeilschepen onderling en de volgorde zeil - spier - motor (6.17).$$),
('kielboot-1', 'kielboot-1.t6', 'theorie', 6, $$Krachten op het schip en hun gevolgen$$,
 $$Kunnen aangeven wat fok en grootzeil doen met het sturen van het schip, en wat er gebeurt bij een onjuiste zeilstand.$$),

-- ---------------- Kielboot II — praktijk
('kielboot-2', 'kielboot-2.p1',  'praktijk',  1, $$Het schip zeilklaar en nachtklaar maken$$,
 $$Als bij Kielboot I, maar uitgebreider: zeilkleden met de droge zijde droog opvouwen, sluitingen controleren, kraanlijn aanslaan en doorzetten, fok aanslaan met de leuvers van onderaf en het zeil niet in het water, fokkenschoten door de lij-ogen met een achtknoop erop. Zo nodig reven, zelflozers instellen. De bemanning is goed gekleed en kan zich omkleden als het weer omslaat; voor iedereen een reddingvest aan boord.$$),
('kielboot-2', 'kielboot-2.p2',  'praktijk',  2, $$Verhalen van het schip$$,
 $$Zonder motor. Alle manieren op spierkracht mogen, zolang het geen gevaar oplevert voor bemanning, materiaal of andere scheepvaart. Op het schip zelf zo veel mogelijk vanuit de kuip werken.$$),
('kielboot-2', 'kielboot-2.p3',  'praktijk',  3, $$Stilliggend hijsen en strijken van de zeilen$$,
 $$Kop nagenoeg in de wind, bemanning voorin of aan de kant van de kraanlijn. Grootzeil: schoot en zeilbandjes los, bij gaffelzeil gaffel op circa 45 graden, vallen samen, klauwval vast, halstalie vast, piek stellen tot er een plooi van nok naar hals staat. Fok: schoothoek lostrekken, hijsen, strietsen, val beleggen, vallen en kraanlijn opschieten.$$),
('kielboot-2', 'kielboot-2.p4',  'praktijk',  4, $$Stand en bediening van de zeilen$$,
 $$Op rechte koers en in de bocht zo veel mogelijk de juiste zeilstand: zo ver gevierd als kan zonder dat het voorlijk kilt, met bescheiden killen van de fok bij oploeven en van het grootzeil bij afvallen. De zeilen ondersteunen het sturen.$$),
('kielboot-2', 'kielboot-2.p5',  'praktijk',  5, $$Sturen, roer- en schootbediening$$,
 $$Met roer en zeilen een rechte koers en bochten varen, zó dat een aangewezen punt zonder onnodige omwegen wordt aangezeild.$$),
('kielboot-2', 'kielboot-2.p6',  'praktijk',  6, $$Overstag gaan$$,
 $$Van hoog aan de wind over de ene boeg naar hoog aan de wind over de andere, met de commando's klaar om te wenden, ree, zo nodig fok bak, fok over en fok aan. De fok wordt zonder rukken strak gezet, er wordt zo min mogelijk roer gegeven, en de stuurman gaat met het gezicht naar voren verzitten.$$),
('kielboot-2', 'kielboot-2.p7',  'praktijk',  7, $$Opkruisen in nauw vaarwater$$,
 $$Goed hoog aan de wind zeilen met de rest van het scheepvaartverkeer in de gaten. Waait de wind van een van de oevers, dan vaar je de korte slag met een knik in de schoot, om genoeg snelheid te houden voor een vloeiende overstagmanoeuvre.$$),
('kielboot-2', 'kielboot-2.p8',  'praktijk',  8, $$Gijpen en gijpen kunnen vermijden$$,
 $$Gijpen als bij Kielboot I, maar nu ook kunnen vermijden als de omstandigheden dat vragen: een stormrondje varen — rustig oploeven, na de overstagmanoeuvre vlot afvallen met het grootzeil flink los en de fok bak — of het grootzeil strijken.$$),
('kielboot-2', 'kielboot-2.p9',  'praktijk',  9, $$Afvaren van hogerwal$$,
 $$Als bij Kielboot I, en zo nodig deinzend: schip in de wind, gewicht evenredig verdeeld, schoten los, fok gebundeld, stuurman aan de toekomstige loefzijde. De afduwer houdt het schip aan de voorstag vast en zet krachtig recht achteruit af; de roerganger geeft roer voor een deinzend schip en valt vol over de vooraf afgesproken boeg, bij voorkeur zonder fok bak.$$),
('kielboot-2', 'kielboot-2.p10', 'praktijk', 10, $$Aankomen aan hogerwal (onder alle omstandigheden)$$,
 $$Ook zonder dwarspeiling. Landvasten klaar en aan het schip vast. Het schip ligt stil vlak voor de aangewezen plaats, op een aan de windse koers en zo veel mogelijk loodrecht op de wal; de snelheidsregeling is zichtbaar en de zeilen killen volledig. Wie vastmaakt blijft zo lang mogelijk laag, met het landvast in de hand, en stapt via de loefzijde aan wal — niet springen.$$),
('kielboot-2', 'kielboot-2.p11', 'praktijk', 11, $$Afmeren van het schip$$,
 $$Zo vastleggen dat ook op lange termijn geen schade aan eigen of andere schepen mogelijk is. Minder dan 3 of meer dan 6 lijnen naar de wal is altijd fout; kies ze zo lang mogelijk en leg eerst de lijnen vast die de natuurlijke beweging van het schip tegengaan.$$),
('kielboot-2', 'kielboot-2.p12', 'praktijk', 12, $$Kunnen reven op het eigen schip$$,
 $$Kunnen aangeven wanneer reven nodig is — op grond van schip, zeilwater, windkracht en geoefendheid van de bemanning — en het op de eigen boot ook daadwerkelijk kunnen.$$),
('kielboot-2', 'kielboot-2.p13', 'praktijk', 13, $$Toepassing van de reglementen$$,
 $$De uitwijkregels voor het eigen vaargebied toepassen en een uitwijkmanoeuvre tijdig inzetten. De bemanning mag waarschuwen voor andere scheepvaart.$$),
('kielboot-2', 'kielboot-2.p14', 'praktijk', 14, $$Man over boord manoeuvre$$,
 $$Constateren en roepen, "zwem" toeroepen, drijfmiddel toewerpen, iemand laten wijzen. Vanaf elke koers afvallen naar voor de wind, doorvaren tot je over de aan de windse lijn heen bent (zo'n 4 bootlengtes), oploeven, "man dwars", overstag, snelheid regelen en langzaam aan lij langsvaren. Bemanning klaar aan loef, "man vast", fok bak. De drenkeling aan loef op het draaipunt achter het want zijdelings en horizontaal binnenhalen. Bijliggen en EHBO toepassen.$$),
('kielboot-2', 'kielboot-2.p15', 'praktijk', 15, $$Loskomen van aan de grond$$,
 $$In volgorde van moeilijkheid: zo snel mogelijk van de ondiepte af sturen; het schip krengen om diepgang te verminderen (pas op voor de gijp bij voor de windse koersen); de vaarboom pakken en door de wind bomen of een gijp forceren; en als laatste het zeil strijken en de boot dezelfde weg terugduwen of laten slepen.$$),
('kielboot-2', 'kielboot-2.p16', 'praktijk', 16, $$Gebruik buitenboordmotor$$,
 $$Met minstens één motor overweg kunnen: start- en stopprocedure kennen, zo nodig de choke, en controleren of het roer de schroef kan raken. Aanleggen en afvaren van hogerwal, goed afmeren op de eigen ligplaats, keren en stoppen. Zijn er mensen in het water vlakbij, dan gaat de motor uit.$$),

-- ---------------- Kielboot II — theorie
('kielboot-2', 'kielboot-2.t1', 'theorie', 1, $$Schiemanswerk$$,
 $$Bij naam kennen, kunnen leggen en de functie kennen van: twee halve steken (de eerste slippend), achtknoop, paalsteek, platte knoop, mastworp (met slipsteek als borg), enkele schootsteek. Plus een lijn opschieten en beleggen op een kikker.$$),
('kielboot-2', 'kielboot-2.t2', 'theorie', 2, $$Zeiltermen$$,
 $$De termen van Kielboot I, aangevuld met deinzen, opschieten en beleggen.$$),
('kielboot-2', 'kielboot-2.t3', 'theorie', 3, $$Onderdelen$$,
 $$Van eigen boot en tuigage, in de praktijk en op een tekening, minstens 25 onderdelen bij naam noemen. In ieder geval: blok, landvast, kiel, helmstok, roer, mast, giek, val, schoot, halshoek, schoothoek, grootzeil, fok.$$),
('kielboot-2', 'kielboot-2.t4', 'theorie', 4, $$Veiligheid$$,
 $$Kunnen uitleggen waarom je bij een omgeslagen boot blijft, en de eisen kennen die aan een reddingvest gesteld worden.$$),
('kielboot-2', 'kielboot-2.t5', 'theorie', 5, $$Reglementen$$,
 $$Uit het BPR: de begripsbepalingen voor motorschip, groot en klein schip, zeilschip en zeilplank (1.01), voorzorgsmaatregelen (1.04), afwijking (1.05), tegengestelde koersen inclusief kleine zeilschepen onderling en zeil - spier - motor (6.01, 6.03, 6.04), voorbijlopen (6.10) en kruisende koersen (6.17). Ook weten dat er naast het BPR andere reglementen gelden en waar je die vindt.$$),
('kielboot-2', 'kielboot-2.t6', 'theorie', 6, $$Krachten op het schip en hun gevolgen$$,
 $$Wat fok en grootzeil doen met het sturen, wat er gebeurt bij een onjuiste zeilstand, en wat de helling van de boot met de sturing doet.$$),
('kielboot-2', 'kielboot-2.t7', 'theorie', 7, $$Gedragsregels$$,
 $$De goede gebruiken ten opzichte van andere watersporters kennen, waaronder wedstrijdzeilers, en de verantwoording ten opzichte van het milieu.$$),
('kielboot-2', 'kielboot-2.t8', 'theorie', 8, $$Weersinvloeden$$,
 $$Het weerbericht kunnen interpreteren met het oog op de veiligheid van het kielbootvaren en de eigen vaardigheid, en voortekenen van plotselinge weersomslagen zoals onweer en zware windvlagen tijdig herkennen.$$),
('kielboot-2', 'kielboot-2.t9', 'theorie', 9, $$Vaarproblematiek andersoortige schepen$$,
 $$Het gevaar kennen van de dode hoek en van de zuiging van grote schepen. Weten dat grote schepen op smal vaarwater niet kunnen wijken, en dat ook grote vrachtschepen sterk kunnen verlijeren.$$),

-- ---------------- Kielboot III — praktijk
('kielboot-3', 'kielboot-3.p1',  'praktijk',  1, $$Het aanslaan van de zeilen$$,
 $$Een zeil kunnen aanslaan aan de rondhouten van het eigen schip.$$),
('kielboot-3', 'kielboot-3.p2',  'praktijk',  2, $$Het schip zeilklaar maken en klaarmaken voor de nacht$$,
 $$Als bij Kielboot II: inventaris, zeilkleden droog opvouwen, kraanlijn aanslaan en doorzetten, mik of schaar veilig opbergen, fok aanslaan met de leuvers van onderaf, fokkenschoten door de lij-ogen met achtknoop, grootzeilvallen aanslaan, zo nodig reven, zelflozers instellen. Bemanning goed gekleed met de mogelijkheid zich om te kleden, en voor iedereen een reddingvest.$$),
('kielboot-3', 'kielboot-3.p3',  'praktijk',  3, $$Verhalen van het schip$$,
 $$Zonder motor, op spierkracht, zonder gevaar voor bemanning, materiaal of andere scheepvaart, en op het schip zelf zo veel mogelijk vanuit de kuip.$$),
('kielboot-3', 'kielboot-3.p4',  'praktijk',  4, $$Hijsen en strijken van de zeilen, stilliggend en varend$$,
 $$Stilliggend als bij Kielboot II. Varend: fokkenval vast aan de nagelbank, nog één zeilbandje met slipsteek, kraanlijn strak aan de toekomstige loefzijde, schoot met slipsteek klaar. Op koersen hoger dan halve wind eerst het grootzeil en dan de fok; op ruimere koersen eerst de fok, vaart maken, oploeven tot aan de wind en dan het grootzeil. Let goed op het andere scheepvaartverkeer.$$),
('kielboot-3', 'kielboot-3.p5',  'praktijk',  5, $$Stand en bediening van de zeilen$$,
 $$Op rechte koers en in de bocht zo veel mogelijk de juiste zeilstand: zo ver gevierd als kan zonder dat het voorlijk kilt. De zeilen ondersteunen het sturen.$$),
('kielboot-3', 'kielboot-3.p6',  'praktijk',  6, $$Bovenwinds gelegen punt kunnen bezeilen$$,
 $$Met zo min mogelijk slagen een in de wind gelegen punt bezeilen, en met de "achterlijker dan dwars"-peiling goed bepalen wanneer je overstag kunt. Moeten er een lange en een korte slag gemaakt worden, dan bij voorkeur met de korte slag bij het punt aankomen.$$),
('kielboot-3', 'kielboot-3.p7',  'praktijk',  7, $$Opkruisen in nauw vaarwater$$,
 $$Goed hoog aan de wind zeilen met oog voor het andere verkeer. Waait de wind van een van de oevers, dan de korte slag met een knik in de schoot varen voor genoeg snelheid om vloeiend overstag te kunnen.$$),
('kielboot-3', 'kielboot-3.p8',  'praktijk',  8, $$Gijpen en gijpen kunnen vermijden$$,
 $$De gijp zien aankomen en de bemanning waarschuwen; het zeil komt pal voor de wind over en het schip blijft een vloeiende koers varen. Vermijden kan met een stormrondje — rustig oploeven, na de overstagmanoeuvre vlot afvallen met het grootzeil los en de fok bak — of door het grootzeil te strijken.$$),
('kielboot-3', 'kielboot-3.p9',  'praktijk',  9, $$Afvaren van en aankomen aan hogerwal$$,
 $$Afvaren als bij Kielboot II, zo nodig deinzend. Aankomen moet ook zonder dwarspeiling: landvasten klaar en vast aan het schip, stilliggen vlak voor de aangewezen plaats op een aan de windse koers, zo veel mogelijk loodrecht op de wal, met zichtbare snelheidsregeling en volledig killende zeilen. Wie vastmaakt blijft laag en stapt via loef aan wal — niet springen.$$),
('kielboot-3', 'kielboot-3.p10', 'praktijk', 10, $$Man over boord manoeuvre$$,
 $$Constateren en roepen, "zwem" toeroepen, drijfmiddel toewerpen, laten wijzen. Afvallen naar voor de wind tot je over de aan de windse lijn heen bent (zo'n 4 bootlengtes), oploeven, "man dwars", overstag, snelheid regelen en langzaam aan lij langsvaren. "Man vast", fok bak, de drenkeling aan loef op het draaipunt achter het want zijdelings en horizontaal binnenhalen. Bijliggen en EHBO toepassen.$$),
('kielboot-3', 'kielboot-3.p11', 'praktijk', 11, $$Aankomen aan lagerwal$$,
 $$Stootwillen op de juiste plaats, afstoplijn klaar bij het draaipunt, vallen vrij uitlopend, kraanlijn aan de toekomstige loefzijde. Fok zo nodig eerst strijken, grootzeil bovenwinds strijken op aan de windse koers: voorstrijk, grootschoot vast, vlot strijken, aan loef binnenhalen, zeilbandjes vast. Aankomen via de opdraaimethode of met de afstoplijn. Houd het schip vierkant, bemanning laag in de kuip en mee uitkijken, en houd nooit met handen of voeten af.$$),
('kielboot-3', 'kielboot-3.p12', 'praktijk', 12, $$Afmeren$$,
 $$Zo vastleggen dat ook op lange termijn geen schade mogelijk is. Minder dan 3 of meer dan 6 lijnen naar de wal is altijd fout; zo lang mogelijk gekozen, en eerst de lijnen die de natuurlijke beweging van het schip tegengaan.$$),
('kielboot-3', 'kielboot-3.p13', 'praktijk', 13, $$Kunnen reven op het eigen schip$$,
 $$Kunnen aangeven wanneer reven nodig is — schip, zeilwater, windkracht, geoefendheid van de bemanning — en het op de eigen boot ook kunnen.$$),
('kielboot-3', 'kielboot-3.p14', 'praktijk', 14, $$Eenvoudig ankeren$$,
 $$In een noodgeval het aanwezige anker kunnen gebruiken: geen lijnen om het anker, het anker moet zich kunnen ingraven, en het schip blijft tijdens het ankeren nagenoeg in de wind liggen.$$),
('kielboot-3', 'kielboot-3.p15', 'praktijk', 15, $$Eenvoudige zeil- en scheepstrim$$,
 $$De functie van de bolling van het zeil kennen en die zo nodig kunnen beïnvloeden. De helling van het schip blijft zo veel mogelijk constant, een ietsje naar lij.$$),
('kielboot-3', 'kielboot-3.p16', 'praktijk', 16, $$Loskomen van aan de grond$$,
 $$In volgorde van moeilijkheid: van de ondiepte af sturen; krengen om diepgang te verminderen (let op de gijp bij voor de windse koersen); de vaarboom pakken en door de wind bomen of een gijp forceren; en als laatste het zeil strijken en dezelfde weg terugduwen of laten slepen.$$),
('kielboot-3', 'kielboot-3.p17', 'praktijk', 17, $$Bedienen van een binnen- of buitenboordmotor$$,
 $$Met minstens één motor overweg kunnen: start- en stopprocedure, zo nodig de choke, en bij een buitenboordmotor controleren of het roer de schroef kan raken. Aanleggen en afvaren van hogerwal, afmeren op de eigen ligplaats, keren, stoppen en stilliggen op open water. Zijn er mensen in het water vlakbij, dan gaat de motor uit.$$),
('kielboot-3', 'kielboot-3.p18', 'praktijk', 18, $$Schiemanswerk$$,
 $$Weten welk touwwerk waarvoor geschikt is — landvasten, vallen, sleeplijn, ankerlijn — en het vrij van zand, scherpe randen en UV-licht houden. Steken en knopen met hun toepassing: twee halve steken, slipsteek, achtknoop, platte knoop, enkele en dubbele schootsteek, mastworp op twee manieren, paalsteek, een tros opschieten, beleggen op bolder, klamp of nagel.$$),
('kielboot-3', 'kielboot-3.p19', 'praktijk', 19, $$Aanvarings- en achtergrondpeiling kunnen maken$$,
 $$Bij kruisende koersen vaststellen of er aanvaringsgevaar ontstaat, door over het andere schip een peiling op de achtergrond te nemen.$$),
('kielboot-3', 'kielboot-3.p20', 'praktijk', 20, $$Toepassing van de reglementen$$,
 $$De uitwijkregels voor het eigen vaargebied toepassen en een uitwijkmanoeuvre tijdig inzetten. De bemanning mag waarschuwen voor andere scheepvaart.$$),
('kielboot-3', 'kielboot-3.p21', 'praktijk', 21, $$Terminologie$$,
 $$Zo veel mogelijk de juiste naamgeving gebruiken, binnen de boot én tussen schepen en personen onderling.$$),

-- ---------------- Kielboot III — theorie
('kielboot-3', 'kielboot-3.t1',  'theorie',  1, $$Schiemanswerk$$,
 $$De steken van Kielboot II, aangevuld met mastworp en schootsteek op twee manieren, en beleggen op een bolder. Daarnaast: touwsoorten verschillen in rekvermogen, breeksterkte, slijtvastheid, wateropname en UV-bestendigheid; geslagen en gevlochten touwwerk herkennen; weten welk touw waarvoor geschikt is; en het begrip schavielen met de maatregelen daartegen kunnen beschrijven.$$),
('kielboot-3', 'kielboot-3.t2',  'theorie',  2, $$Zeiltermen$$,
 $$De termen van Kielboot II, aangevuld met bovenlangs, onderlangs, dwarspeiling, bezeild, binnen de wind, korte en lange slag, opschieter, zuigen, duiken, planeren, volvallen, verhalen, verlijeren, drift, bijliggen en bakhouden.$$),
('kielboot-3', 'kielboot-3.t3',  'theorie',  3, $$Onderdelen$$,
 $$Van eigen boot en tuigage, in de praktijk en op afbeeldingen, minstens 40 onderdelen bij naam noemen. In ieder geval: voorsteven, spiegel, sluiting, kous, blok, stootkussen, hoosvat, landvast, kiel, helmstok, roer, roerblad, mast, giek, val, halstalie, schoot, voor-, achter- en onderlijk, hals- en schoothoek, grootzeil, fok.$$),
('kielboot-3', 'kielboot-3.t4',  'theorie',  4, $$Veiligheid$$,
 $$Kunnen uitleggen waarom je bij een omgeslagen boot blijft, en de eisen kennen die aan een zwemvest of reddingvest gesteld worden.$$),
('kielboot-3', 'kielboot-3.t5',  'theorie',  5, $$Reglementen$$,
 $$Een flink uitgebreidere lijst uit het BPR dan bij Kielboot II: begripsbepalingen, tekens en lichten, geluidsseinen en verkeerstekens, de vaarregels, bruggen en sluizen. Ook weten welke andere reglementen in het eigen vaargebied gelden, waar je ze vindt, en dat voor bepaalde schepen een Klein Vaarbewijs verplicht is. De volledige artikelopsomming staat in het handboek.$$),
('kielboot-3', 'kielboot-3.t6',  'theorie',  6, $$Krachten op het schip en hun gevolgen$$,
 $$De begrippen kracht en koppel kennen en kunnen gebruiken: wat fok en grootzeil met het sturen doen, wat een onjuiste zeilstand oplevert, wat de helling doet, en hoe uit de windkracht op het zeil zowel drift als voortstuwing ontstaat. Plus de oorzaken van stabiliteit bij scherpe jachten, en het verschil tussen gewichts- en vormstabiliteit.$$),
('kielboot-3', 'kielboot-3.t7',  'theorie',  7, $$Gedragsregels, vlagvoering en jachtetiquette$$,
 $$De goede gebruiken ten opzichte van andere watersporters kennen, waaronder wedstrijdzeilers, de verantwoording ten opzichte van het milieu, en de vlagvoering van het eigen schip.$$),
('kielboot-3', 'kielboot-3.t8',  'theorie',  8, $$Weersinvloeden$$,
 $$Het weerbericht kunnen interpreteren met het oog op veiligheid en eigen vaardigheid, en voortekenen van plotselinge weersomslagen tijdig herkennen. Ook weten welke windsnelheden in m/s bij de stappen van de schaal van Beaufort horen, en hoe de omschrijvingen in waarschuwingen daarmee samenhangen.$$),
('kielboot-3', 'kielboot-3.t9',  'theorie',  9, $$Vaarproblematiek andersoortige schepen$$,
 $$Het gevaar kennen van de dode hoek en van de zuiging van grote schepen. Weten dat grote schepen op smal vaarwater niet kunnen wijken, en dat ook grote vrachtschepen sterk kunnen verlijeren.$$),
('kielboot-3', 'kielboot-3.t10', 'theorie', 10, $$Dagelijks onderhoud van het eigen schip$$,
 $$Controleren of bevestigingsmaterialen vastzitten, ook boven in de mast; kleine beschadigingen bijwerken; het schip schoonhouden. Voor de buitenboordmotor: brandstof bijvullen, smering van motor en schroefas controleren, en vreemde geluiden herkennen en doorgeven.$$),
('kielboot-3', 'kielboot-3.t11', 'theorie', 11, $$Het kennen van twee andere reefsystemen dan die op het eigen schip$$,
 $$Theoretische kennis van het reefsysteem van het eigen schip en van de belangrijkste foutoorzaken daarbij, plus twee andere reefsystemen kennen.$$),

-- ---------------- Kielboot IV — praktijk
('kielboot-4', 'kielboot-4.p1',  'praktijk',  1, $$Aanslaan van de zeilen$$,
 $$Een zeil kunnen aanslaan aan de rondhouten van het eigen schip.$$),
('kielboot-4', 'kielboot-4.p2',  'praktijk',  2, $$Schip zeilklaar maken en klaarmaken voor de nacht$$,
 $$Als bij Kielboot III: inventaris, zeilkleden droog opvouwen en niet in de weg opbergen, kraanlijn aanslaan en doorzetten, fok aanslaan met de leuvers van onderaf, fokkenschoten door de lij-ogen met achtknoop, grootzeilvallen aanslaan, zo nodig reven, zelflozers instellen. Bemanning goed gekleed en in staat zich om te kleden, en voor iedereen een reddingvest.$$),
('kielboot-4', 'kielboot-4.p3',  'praktijk',  3, $$Verhalen van het schip$$,
 $$Zonder motor, op spierkracht, zonder gevaar voor bemanning, materiaal of andere scheepvaart, en op het schip zelf zo veel mogelijk vanuit de kuip.$$),
('kielboot-4', 'kielboot-4.p4',  'praktijk',  4, $$Hijsen en strijken van de zeilen, stilliggend en varend$$,
 $$Als bij Kielboot III. Varend: fokkenval vast aan de nagelbank, één zeilbandje met slipsteek, kraanlijn strak aan de toekomstige loefzijde, grootschoot met slipsteek klaar. Op koersen hoger dan halve wind eerst grootzeil dan fok; op ruimere koersen eerst de fok, vaart maken, oploeven en dan het grootzeil. Bij weinig wind, vaak bij bruggen, mag het grootzeil ook op ruimere koers omhoog.$$),
('kielboot-4', 'kielboot-4.p5',  'praktijk',  5, $$Stand en bediening van de zeilen$$,
 $$Op rechte koers en in de bocht zo veel mogelijk de juiste zeilstand: zo ver gevierd als kan zonder dat het voorlijk kilt. De zeilen ondersteunen het sturen.$$),
('kielboot-4', 'kielboot-4.p6',  'praktijk',  6, $$Bovenwinds gelegen punt kunnen bezeilen$$,
 $$Met zo min mogelijk slagen, en met de "achterlijker dan dwars"-peiling bepalen wanneer je overstag kunt. Bij een lange en een korte slag bij voorkeur met de korte slag bij het punt aankomen.$$),
('kielboot-4', 'kielboot-4.p7',  'praktijk',  7, $$Opkruisen in nauw vaarwater$$,
 $$Goed hoog aan de wind zeilen met oog voor het andere verkeer, en bij wind van een van de oevers de korte slag met een knik in de schoot varen.$$),
('kielboot-4', 'kielboot-4.p8',  'praktijk',  8, $$Gijpen en gijpen kunnen vermijden$$,
 $$De gijp zien aankomen en de bemanning waarschuwen; het zeil komt pal voor de wind over en het schip blijft een vloeiende koers varen. Vermijden kan met een stormrondje of door het grootzeil te strijken.$$),
('kielboot-4', 'kielboot-4.p9',  'praktijk',  9, $$Afvaren van en aankomen aan hogerwal$$,
 $$Als bij Kielboot III, zo nodig deinzend, en aankomen ook zonder dwarspeiling: stilliggen vlak voor de aangewezen plaats op een aan de windse koers, loodrecht op de wal, met zichtbare snelheidsregeling en volledig killende zeilen. Via loef aan wal stappen, niet springen.$$),
('kielboot-4', 'kielboot-4.p10', 'praktijk', 10, $$Man over boord manoeuvre kunnen uitvoeren$$,
 $$Constateren, "zwem" toeroepen, drijfmiddel toewerpen, laten wijzen. Afvallen naar voor de wind tot over de aan de windse lijn (zo'n 4 bootlengtes), oploeven, "man dwars", overstag, snelheid regelen en langzaam aan lij komen. "Man vast", fok bak, de drenkeling aan loef op het draaipunt achter het want zijdelings en horizontaal binnenhalen. Bijliggen en EHBO toepassen.$$),
('kielboot-4', 'kielboot-4.p11', 'praktijk', 11, $$Wegvaren van en aankomen aan lagerwal$$,
 $$Afvaren: vaarboom klaar aan de walzijde, schip zo nodig eerst draaien, en bepalen of het door de wind gedrukt moet worden (weinig wind) of juist niet (zwaar schip of veel wind). Vaart geven via vaarboom, giek of want, en de periode zonder zeil zo kort mogelijk houden. Aankomen als bij Kielboot III: stootwillen, afstoplijn bij het draaipunt, grootzeil bovenwinds strijken, dan de opdraai- of afstopmethode.$$),
('kielboot-4', 'kielboot-4.p12', 'praktijk', 12, $$Afmeren$$,
 $$Zo vastleggen dat ook op lange termijn geen schade mogelijk is. Minder dan 3 of meer dan 6 lijnen naar de wal is altijd fout; zo lang mogelijk gekozen, en eerst de lijnen die de natuurlijke beweging van het schip tegengaan.$$),
('kielboot-4', 'kielboot-4.p13', 'praktijk', 13, $$Kunnen reven op het eigen schip$$,
 $$Kunnen aangeven wanneer reven nodig is — schip, zeilwater, windkracht, geoefendheid van de bemanning — en het op de eigen boot ook kunnen.$$),
('kielboot-4', 'kielboot-4.p14', 'praktijk', 14, $$Ankeren en anker op gaan$$,
 $$Ankeren: proefopschieter op de ankerplaats, grondgesteldheid en diepte bepalen, ankertros vast aan een degelijk punt, ankerboei vast. Met gestreken fok stilliggen, anker laten vallen zodra het schip stilligt (niet werpen), tros vieren, zeil strijken zodra het anker houdt, ankerbol hijsen. Regelmatig controleren op krabben. Anker op: tros aan de toekomstige loefzijde, ankerbol strijken, tros inhalen, grootzeil hijsen, anker ophalen en over de gekozen boeg wegvaren, anker schoonmaken.$$),
('kielboot-4', 'kielboot-4.p15', 'praktijk', 15, $$Varen in kanalen, passeren van bruggen en sluizen$$,
 $$De bijbehorende technieken en gedragsregels kennen: op je beurt wachten, geen rondjes varen voor de brugopening, zo nodig een sleepje vragen of accepteren, de ketting gebruiken om door de brug te komen, en zo nodig de mast strijken voor een rustige passage.$$),
('kielboot-4', 'kielboot-4.p16', 'praktijk', 16, $$Doelmatigheid in vaargedrag vertonen$$,
 $$Met grote nauwkeurigheid varen: zo min mogelijk gevaren meters tussen de opdracht en de uitvoering, en reglementproblemen inzichtelijk voorkomen.$$),
('kielboot-4', 'kielboot-4.p17', 'praktijk', 17, $$Zeil- en scheepstrim$$,
 $$De bolling van het zeil kunnen beïnvloeden en de functie kennen van de spanning op de lijkenbindsels, de helling van de gaffel en de halstalie; voor de fok de reguleerlijntjes in voor- en achterlijk en de verstelbare lij-ogen. De helling blijft constant, een ietsje naar lij, en de langsscheepse ballastverdeling geeft zo min mogelijk turbulentie.$$),
('kielboot-4', 'kielboot-4.p18', 'praktijk', 18, $$Loskomen van aan de grond$$,
 $$In volgorde van moeilijkheid: van de ondiepte af sturen; krengen om diepgang te verminderen; de vaarboom pakken en door de wind bomen of een gijp forceren; en als laatste het zeil strijken en dezelfde weg terugduwen of laten slepen.$$),
('kielboot-4', 'kielboot-4.p19', 'praktijk', 19, $$Bedienen van een binnen- of buitenboordmotor$$,
 $$Start- en stopprocedure, zo nodig de choke, en bij een buitenboordmotor controleren of het roer de schroef kan raken. Aanleggen en afvaren van hoger- én lagerwal, afmeren op de eigen ligplaats, keren, stoppen en stilliggen op open water. Zijn er mensen in het water vlakbij, dan gaat de motor uit.$$),
('kielboot-4', 'kielboot-4.p20', 'praktijk', 20, $$Schiemanswerk$$,
 $$Als bij Kielboot III — touwsoorten en hun gebruik, twee halve steken, slipsteek, achtknoop, platte knoop, enkele en dubbele schootsteek, mastworp op twee manieren, paalsteek, opschieten en beleggen — aangevuld met een splits in driestrengs touwwerk en een benaaide takeling.$$),
('kielboot-4', 'kielboot-4.p21', 'praktijk', 21, $$Aanvarings- en achtergrondpeiling kunnen maken$$,
 $$Bij kruisende koersen vaststellen of er aanvaringsgevaar ontstaat, door over het andere schip een peiling op de achtergrond te nemen.$$),
('kielboot-4', 'kielboot-4.p22', 'praktijk', 22, $$Toepassing van de reglementen$$,
 $$De uitwijkregels kunnen toepassen, en een uitwijkmanoeuvre tijdig inzetten.$$),
('kielboot-4', 'kielboot-4.p23', 'praktijk', 23, $$Terminologie$$,
 $$Zo veel mogelijk de juiste naamgeving gebruiken, binnen de boot én tussen schepen en personen onderling.$$),

-- ---------------- Kielboot IV — theorie
('kielboot-4', 'kielboot-4.t1',  'theorie',  1, $$Schiemanswerk$$,
 $$Het verschil tussen gevlochten en geslagen touwwerk kunnen aangeven — in fabricage, verwerking én gebruik.$$),
('kielboot-4', 'kielboot-4.t2',  'theorie',  2, $$Dagelijks onderhoud van het eigen schip en de binnen- of buitenboordmotor$$,
 $$Controle op het vastzitten van bevestigingsmaterialen, ook boven in de mast; kleine beschadigingen bijwerken; het schip schoonhouden. Motor: brandstof bijvullen, smering van motor en schroefas controleren en aanvullen, vreemde geluiden herkennen en doorgeven. Lensruimte schoonhouden en vervuild lenswater inleveren bij een depot.$$),
('kielboot-4', 'kielboot-4.t3',  'theorie',  3, $$Scheepsbouw, materialen en onderdelen$$,
 $$Benaming, toepassing en functie van scheepsonderdelen, met de voor- en nadelen van verschillende systemen. Jachten onderscheiden naar hoofdtype (scherpe jachten, ronde en platbodems, meerrompsjachten) en hoofdspantvorm (rondspant, knikspant, S-spant). Verder: romponderdelen, driftbeperking (kiel, midzwaard, zijzwaarden), roerconstructies (aangehangen en doorgestoken), rondhouten, staand en lopend want, de zeilen en hun onderdelen, en de reefsystemen.$$),
('kielboot-4', 'kielboot-4.t4',  'theorie',  4, $$Veiligheid en (blessure)preventie$$,
 $$De veiligheid van de opvarenden moet preventief gewaarborgd zijn — in het schip zelf, in de kleding en in de veiligheidsmiddelen.$$),
('kielboot-4', 'kielboot-4.t5',  'theorie',  5, $$Reglementen$$,
 $$De uitgebreide BPR-lijst van Kielboot III, maar nu nadrukkelijk in toepassing: artikelen uit het hoofd kennen is niet genoeg, je moet ze op geschetste situaties kunnen toepassen. Het handboek waarschuwt dat dit onderdeel op het examen het lastigst blijkt. Ook weten welke andere reglementen in het eigen vaargebied gelden en dat voor bepaalde schepen een Klein Vaarbewijs verplicht is.$$),
('kielboot-4', 'kielboot-4.t6',  'theorie',  6, $$Navigatie$$,
 $$De betekenis van de rode en groene tonnen en de splitsingstonnen volgens het SIGNI-systeem kennen, en overweg kunnen met waterkaarten en de Almanak voor Watertoerisme deel 2.$$),
('kielboot-4', 'kielboot-4.t7',  'theorie',  7, $$Vaarproblematiek grote schepen$$,
 $$Besef hebben van de problemen van de grote scheepvaart, met de begrippen diepgang, dode hoek, windvang in ongeladen toestand, zuiging en benodigde manoeuvreerruimte.$$),
('kielboot-4', 'kielboot-4.t8',  'theorie',  8, $$Vlagvoering en jachtetiquette$$,
 $$De vlagvoering voor schepen met één mast kennen, de verantwoording ten aanzien van het milieu, en de goede gebruiken ten opzichte van andere watersporters en wedstrijdzeilers.$$),
('kielboot-4', 'kielboot-4.t9',  'theorie',  9, $$Stabiliteit$$,
 $$De oorzaken van stabiliteit kennen bij scherpe jachten, bij platbodems en ronde schepen, en bij meerrompsjachten.$$),
('kielboot-4', 'kielboot-4.t10', 'theorie', 10, $$Voortstuwende en remmende krachten$$,
 $$Met vectoren kunnen aangeven waarom een schip vooruit gaat, met de begrippen kracht, koppel en moment.$$),
('kielboot-4', 'kielboot-4.t11', 'theorie', 11, $$Ankergerei$$,
 $$De onderdelen schacht, stok, kruis, armen en vloeien kennen; het verschil tussen lichtgewicht- en volgewichtankers kunnen aangeven; en het Hollands stokanker, de dreg, de klapdreg, het Danforth-anker en het ploegschaaranker herkennen en benoemen.$$),
('kielboot-4', 'kielboot-4.t12', 'theorie', 12, $$De meest voorkomende scheepssoorten in het eigen vaargebied herkennen en benoemen$$,
 $$Van minstens de helft van de passerende schepen een naam of een redelijk nauwkeurige type-omschrijving kunnen geven. De examinator kiest zelf de selectie.$$),

-- ---------------- Buitenboordmotor I/II — praktijk
('bbm-12', 'bbm-12.p1',  'praktijk',  1, $$Het schip vaarklaar maken en klaarmaken voor de nacht$$,
 $$Vaarklaar: controleren op lek- en regenwater, en op inventaris, bevestiging van de motor, brandstof en motorolie. De motor moet goed getrimd staan. Nachtklaar: motor loskoppelen van de benzinetank, losse inventaris opruimen, dekzeil erop.$$),
('bbm-12', 'bbm-12.p2',  'praktijk',  2, $$Benzinetank aansluiten$$,
 $$Een losse tank op de juiste manier aansluiten: nippels goed in elkaar, geen lekkage als je in de bal knijpt, en zorgen voor ontluchten en ventileren.$$),
('bbm-12', 'bbm-12.p3',  'praktijk',  3, $$Uitwendige controle van de motor$$,
 $$De motor aan de buitenkant nalopen op beschadiging aan de schroef en op olielekkage.$$),
('bbm-12', 'bbm-12.p4',  'praktijk',  4, $$Starten van de motor$$,
 $$De motor op de juiste manier starten, met goed gebruik van choke en gas.$$),
('bbm-12', 'bbm-12.p5',  'praktijk',  5, $$Controle op goede werking$$,
 $$De motor stationair laten draaien en controleren op overmatig trillen en op het uitlaten van koelwater.$$),
('bbm-12', 'bbm-12.p6',  'praktijk',  6, $$Gestrekte koers varen$$,
 $$Bij geringe zijwind een rechte koers varen over minstens 200 meter.$$),
('bbm-12', 'bbm-12.p7',  'praktijk',  7, $$Stuurwerking van de motor$$,
 $$Met de motor kunnen sturen, en de boot — ook door de motor om te draaien — in de achteruit zetten, laten stoppen of vaart laten minderen.$$),
('bbm-12', 'bbm-12.p8',  'praktijk',  8, $$Vaart minderen en stoppen$$,
 $$Tijdig gas terugnemen; het stoppen gebeurt achteruitslaand, waarbij het schip op koers blijft. Houd rekening met de hekgolf.$$),
('bbm-12', 'bbm-12.p9',  'praktijk',  9, $$Drijvend voorwerp kunnen benaderen$$,
 $$Een drijvende boei benaderen en zo stoppen dat hij zonder veel moeite aan boord genomen kan worden, rekening houdend met stroom en wind. De boei mag varend niet geraakt worden.$$),
('bbm-12', 'bbm-12.p10', 'praktijk', 10, $$Een acht en een slalom kunnen varen$$,
 $$Sturend met de motor een acht varen en een slalom om een aantal boeien.$$),
('bbm-12', 'bbm-12.p11', 'praktijk', 11, $$Afvaren en aankomen aan een langswal$$,
 $$Aankomen op een aangegeven plaats zonder noemenswaardig af te hoeven houden — let erop dat het schip niet meer stuurt zodra de schroef niet in het werk staat. Wegvaren met het juiste gebruik van trossen en springen.$$),
('bbm-12', 'bbm-12.p12', 'praktijk', 12, $$Afmeren$$,
 $$Deugdelijk vastleggen met voor- en achtertros en een voor- of achterspring, met de juiste keuze welke van de twee. Beleggen op bolder of kikker gaat op de juiste manier.$$),
('bbm-12', 'bbm-12.p13', 'praktijk', 13, $$Ankeren en anker op gaan$$,
 $$Ankeren: in de wind varen, de vaart eruit halen, en het anker overboord zetten zodra de boot stilligt, zonder dat het onklaar raakt. Langzaam achteruit varen en voldoende ankerlijn of ketting steken. Anker op: motor stand-by, en het anker op de juiste manier aan boord opbergen.$$),
('bbm-12', 'bbm-12.p14', 'praktijk', 14, $$Brandstof bijvullen$$,
 $$Met de nodige voorzorgen: losse tanks aan de wal vullen, en maatregelen treffen om morsen te voorkomen.$$),
('bbm-12', 'bbm-12.p15', 'praktijk', 15, $$Schiemanswerk$$,
 $$Vlot kunnen leggen: platte knoop, paalsteek, halve steek, mastworp. Plus een lijn opschieten en beleggen op een kikker of bolder.$$),
('bbm-12', 'bbm-12.p16', 'praktijk', 16, $$Terminologie$$,
 $$Afhankelijk van het type schip acht onderdelen kunnen benoemen, met hun functie.$$),

-- ---------------- Buitenboordmotor I/II — theorie
('bbm-12', 'bbm-12.t1', 'theorie', 1, $$Terminologie van schip en motor$$,
 $$Van het schip: boeg, stuurboord, bakboord, steven, spanten, spiegel, motorsteun, vrijboord. Van de motor: bougie, brandstofslang, carburator, koelwateruitlaat, gas- en chokehandel — met hun functie.$$),
('bbm-12', 'bbm-12.t2', 'theorie', 2, $$Meest voorkomende storingen kunnen verhelpen$$,
 $$Een vette bougie herkennen en reinigen, de brandstofslang op verstopping controleren, de mengverhouding van de brandstof kennen, en een breekpen kunnen vervangen als die er is.$$),
('bbm-12', 'bbm-12.t3', 'theorie', 3, $$Vlagvoering en jachtetiquette$$,
 $$De goede gebruiken ten opzichte van andere watersporters kennen, de verantwoording ten opzichte van het milieu, en de vlagvoering van het eigen schip.$$),
('bbm-12', 'bbm-12.t4', 'theorie', 4, $$Veiligheid$$,
 $$Kunnen uitleggen waarom voorzorgsmaatregelen aan boord nodig zijn, met benzine als brandstof in het achterhoofd. De reddingsmiddelen moeten voor onmiddellijk gebruik klaarliggen, en je kent het gebruik van zwemvest, reddingslijn en reddingsboei.$$),
('bbm-12', 'bbm-12.t5', 'theorie', 5, $$Reglementen$$,
 $$Een brede selectie uit het BPR: begripsbepalingen (schip, motorschip, groot en klein schip, snelle motorboot, waterscooter), verplichtingen van schipper en bemanning, voorzorgsmaatregelen, sturen, scheepsbescheiden, kentekens van kleine schepen, tekens van een stilliggend klein schip, geluidsseinen en noodseinen, en de vaarregels voor tegengestelde koersen, engtes, voorbijlopen, keren, hoofd- en nevenvaarwater en kruisende koersen. Ook weten dat voor bepaalde schepen een Klein Vaarbewijs verplicht is. De volledige artikelopsomming staat in het handboek.$$),

-- ---------------- Buitenboordmotor III — praktijk
('bbm-3', 'bbm-3.p1',  'praktijk',  1, $$Het schip vaarklaar maken en klaarmaken voor de nacht$$,
 $$Motor juist aanbrengen, slangen goed gebruiken, zorgvuldig vullen met voorzorgen tegen morsen, reservebrandstof goed stouwen. Motor en eventueel roer borgen, inventaris en verlichting controleren, en op de juiste manier ontluchten en ventileren.$$),
('bbm-3', 'bbm-3.p2',  'praktijk',  2, $$Vaartechnieken: koersen varen, afstoppen, gaande houden, noodstop maken$$,
 $$Gestrekte koers met de schroefwerking (wieleffect) erin verrekend, en bij zijwind zo opsturen dat de koers recht blijft. Afstoppen op motorvermogen. Gaande houden: in wind en stroom op dezelfde plaats blijven zonder dat de boeg wegdraait. Noodstop: gas terug en de motor omdraaien en weer gas geven, of gas terug en in de achteruit — zonder dat het schip door de schroefwerking dwars valt.$$),
('bbm-3', 'bbm-3.p3',  'praktijk',  3, $$Afvaren en aankomen bij hoger- en lagerwal$$,
 $$Aan beide wallen, met goed gebruik van trossen en springen. Ook aan een zachte, ondiepe wal: op tijd de motor optillen bij aankomst, en bij het afvaren eerst het achterschip afduwen.$$),
('bbm-3', 'bbm-3.p4',  'praktijk',  4, $$Man over boord manoeuvre$$,
 $$"Zwem" roepen en iemand laten wijzen in de richting van de drenkeling. De boot aan de loefzijde van de drenkeling tot stilstand brengen en de schroef van hem wegdraaien.$$),
('bbm-3', 'bbm-3.p5',  'praktijk',  5, $$Ankeren en anker op gaan$$,
 $$Een ankermanoeuvre uitvoeren zonder dat het anker onklaar raakt, met genoeg lijn gestoken zodat het zich kan ingraven. Bij het overboord zetten moet het schip langzaam deinzen.$$),
('bbm-3', 'bbm-3.p6',  'praktijk',  6, $$Bijzondere verrichtingen$$,
 $$Achteruit manoeuvreren in een box of tussen twee obstakels door, en zowel voor- als achteruit een acht en een slalom om een aantal boeien varen.$$),
('bbm-3', 'bbm-3.p7',  'praktijk',  7, $$Loskomen van aan de grond$$,
 $$Loskomen door het gewicht van de opvarenden te verplaatsen, met het juiste gebruik van de motor — en weten wanneer je assistentie moet vragen.$$),
('bbm-3', 'bbm-3.p8',  'praktijk',  8, $$Passeren van bruggen en/of sluizen$$,
 $$Een brug of sluis op de juiste wijze benaderen en de juiste seinen geven. Moet je vastmaken, dan op de juiste plaats en manier; in een sluis de boot beleggen met dubbelgenomen lijnen en die op de hand laten slippen.$$),
('bbm-3', 'bbm-3.p9',  'praktijk',  9, $$Aanvarings- en achtergrondpeiling$$,
 $$Met een achtergrondspeiling vaststellen of er gevaar voor aanvaring bestaat.$$),
('bbm-3', 'bbm-3.p10', 'praktijk', 10, $$Toepassing reglementen$$,
 $$De regels uit het BPR toepassen voor zover ze op dit type schip van toepassing zijn.$$),
('bbm-3', 'bbm-3.p11', 'praktijk', 11, $$Langszij een varend schip komen en vastmaken$$,
 $$Eerst dezelfde snelheid gaan varen en dan naar het schip toe sturen, waarbij je de zuiging opvangt. Een tweede man brengt de lijn over: eerst de voortros beleggen, dan een achterspring, dan de achtertros.$$),
('bbm-3', 'bbm-3.p12', 'praktijk', 12, $$Slepen en gesleept worden$$,
 $$Een sleeplijn overbrengen of aannemen en bevestigen, en verschillende sleepwijzen toepassen: op één sleeptros, op twee gekruiste trossen en langszij. Weten dat een rubberboot vooruit slepen heel moeilijk is.$$),
('bbm-3', 'bbm-3.p13', 'praktijk', 13, $$Een tocht in het donker$$,
 $$Varen in een periode waarin de scheepslichten ontstoken moeten zijn, en daarbij de lichten van andere vaartuigen, boeien en haveningangen herkennen en ernaar handelen.$$),
('bbm-3', 'bbm-3.p14', 'praktijk', 14, $$Eenvoudige reparaties aan de motor$$,
 $$Bougie schoonmaken en afstellen, breekpen vervangen, brandstofleiding controleren en koelwaterproblemen oplossen.$$),

-- ---------------- Buitenboordmotor III — theorie
('bbm-3', 'bbm-3.t1',  'theorie',  1, $$Terminologie$$,
 $$De belangrijkste onderdelen van het schip (als bij Buitenboordmotor I/II) en van de motor met hun functie: bougie, brandstofleiding, koelwateruitlaat, breekpen, gas- en chokehandel, startkoord.$$),
('bbm-3', 'bbm-3.t2',  'theorie',  2, $$Veiligheids- en reddingsmiddelen$$,
 $$Het gebruik kennen van drijfhulpmiddel of reddingvest, reddingsboei met reddingslijn, reddingsklos met drijvende lijn en dergelijke.$$),
('bbm-3', 'bbm-3.t3',  'theorie',  3, $$Handelen bij averij$$,
 $$De schade kunnen vaststellen en het schip op zeewaardigheid beoordelen, noodvoorzieningen treffen bij lekkage, en weten welke gegevens je bij een aanvaring opneemt.$$),
('bbm-3', 'bbm-3.t4',  'theorie',  4, $$Eenvoudige EHBO$$,
 $$Overweg kunnen met een eenvoudige verbanddoos en eerste hulp verlenen bij eenvoudige verwondingen. Onderkoeling herkennen en weten hoe te handelen.$$),
('bbm-3', 'bbm-3.t5',  'theorie',  5, $$Reglementen$$,
 $$De BPR-lijst van Buitenboordmotor I/II, uitgebreid met de geluidsseinen van bijlage 6A en een flinke reeks verkeerstekens uit bijlage 7 — verboden en geboden, doorvaartopeningen, en de optische tekens bij vaste en beweegbare bruggen en bij sluizen. Ook weten dat voor bepaalde schepen een Klein Vaarbewijs verplicht is. De volledige opsomming staat in het handboek.$$),
('bbm-3', 'bbm-3.t6',  'theorie',  6, $$Betonning en bebakening$$,
 $$De betonning van het thuiswater kennen: in ieder geval de rode stompe en de groene spitse tonnen, en de scheidingstonnen die in dat vaarwater voorkomen.$$),
('bbm-3', 'bbm-3.t7',  'theorie',  7, $$Krachten op het schip en hun gevolgen$$,
 $$Weten wat scherpe bochten bij hoge snelheid betekenen voor schip en bemanning.$$),
('bbm-3', 'bbm-3.t8',  'theorie',  8, $$Jachtetiquette en vlagvoering$$,
 $$Het voeren van vlaggen en wimpels voor motorschepen, de gebruiken aan boord, en de goede gebruiken ten opzichte van medewatersporters en anderen.$$),
('bbm-3', 'bbm-3.t9',  'theorie',  9, $$Weersinvloeden$$,
 $$Aan veranderende wolkenpatronen een weersvoorspelling kunnen doen, de betekenis van stormwaarschuwingen kennen, en de schaal van Beaufort kennen.$$),
('bbm-3', 'bbm-3.t10', 'theorie', 10, $$Gebruik van almanak en waterkaarten$$,
 $$Almanakken en waterkaarten kunnen gebruiken voor navigatie, en daarin de relevante informatie over het te bevaren gebied opzoeken en toepassen.$$)

) as v(diploma, code, kind, position, title, detail)
join diplomas dp on dp.code = v.diploma
on conflict (code) do update set
  diploma_id = excluded.diploma_id,
  kind       = excluded.kind,
  position   = excluded.position,
  title      = excluded.title,
  detail     = excluded.detail;

-- ---------------------------------------------------------------- sloep/motorvlet
--
-- Het handboek Sloep- en motorvletvaren zet de eisen niet per niveau onder
-- elkaar, maar in één matrix met een kolom per niveau. Die kolommen zijn in de
-- PDF niet betrouwbaar uit te lezen, dus staat hieronder bij alle vier de
-- niveaus dezelfde volledige lijst. Dat is bewust de ruime kant: een eis die
-- er niet bij hoort zie je staan en haal je weg, een eis die ontbreekt zie je
-- nooit. Loop de lijst één keer met het handboek naast je na — zie
-- docs/EISEN.md.

insert into requirements (diploma_id, code, kind, position, title, detail)
select dp.id, dp.code || '.' || v.suffix, v.kind::requirement_kind, v.position, v.title, v.detail
from diplomas dp
cross join (values
  ('p1',  'praktijk',  1, $$Vaarklaar maken en controleren van het schip$$,        $$Het schip en basale zaken$$),
  ('p2',  'praktijk',  2, $$Verzorgen van de waterdichtheid van het schip$$,       $$Het schip en basale zaken$$),
  ('p3',  'praktijk',  3, $$Aan dek werken$$,                                      $$Het schip en basale zaken$$),
  ('p4',  'praktijk',  4, $$Behandeling lijnen en schiemannen$$,                   $$Het schip en basale zaken$$),
  ('p5',  'praktijk',  5, $$Bedienen van de motor$$,                               $$Het schip en basale zaken$$),
  ('p6',  'praktijk',  6, $$Zorg voor de motor en motorkamer$$,                    $$Het schip en basale zaken$$),
  ('p7',  'praktijk',  7, $$Communiceren$$,                                        $$Het schip en basale zaken$$),
  ('p8',  'praktijk',  8, $$Sturen$$,                                              $$Manoeuvreren$$),
  ('p9',  'praktijk',  9, $$Manoeuvreren$$,                                        $$Manoeuvreren$$),
  ('p10', 'praktijk', 10, $$Afvaren van een hogerwal en langswal steiger$$,        $$Havenmanoeuvres$$),
  ('p11', 'praktijk', 11, $$Aankomen aan een hogerwal en langswal steiger$$,       $$Havenmanoeuvres$$),
  ('p12', 'praktijk', 12, $$Afvaren van een hogerwal en lagerwal box$$,            $$Havenmanoeuvres$$),
  ('p13', 'praktijk', 13, $$Aankomen in een hogerwal en lagerwal box$$,            $$Havenmanoeuvres$$),
  ('p14', 'praktijk', 14, $$Afvaren van een lagerwal steiger$$,                    $$Havenmanoeuvres$$),
  ('p15', 'praktijk', 15, $$Aankomen aan een lagerwal steiger$$,                   $$Havenmanoeuvres$$),
  ('p16', 'praktijk', 16, $$Afvaren uit een box met dwarswind$$,                   $$Havenmanoeuvres$$),
  ('p17', 'praktijk', 17, $$Aankomen in een box met dwarswind$$,                   $$Havenmanoeuvres$$),
  ('p18', 'praktijk', 18, $$Afmeren$$,                                             $$Havenmanoeuvres$$),
  ('p19', 'praktijk', 19, $$Gebruik van kaart en almanak$$,                        $$Navigatie$$),
  ('p20', 'praktijk', 20, $$Gebruik navigatie-instrumenten$$,                      $$Navigatie$$),
  ('p21', 'praktijk', 21, $$Navigeren aan boord$$,                                 $$Navigatie$$),
  ('p22', 'praktijk', 22, $$Tochtvoorbereiding en het aanlopen van havens$$,       $$Tochtvaren$$),
  ('p23', 'praktijk', 23, $$Passeren van sluizen en bruggen$$,                     $$Tochtvaren$$),
  ('p24', 'praktijk', 24, $$Toepassen van de reglementen$$,                        $$Tochtvaren$$),
  ('p25', 'praktijk', 25, $$Nachtvaren$$,                                          $$Tochtvaren — in het handboek pas vanaf Schipper (CWO III)$$),
  ('p26', 'praktijk', 26, $$Gebruik van de veiligheidsuitrusting en reddingsmiddelen aan boord$$, $$Noodsituaties$$),
  ('p27', 'praktijk', 27, $$Man over boord$$,                                      $$Noodsituaties$$),
  ('p28', 'praktijk', 28, $$Slepen en gesleept worden$$,                           $$Noodsituaties — hiervoor bestaat een aparte module; verplicht voor All Round Schipper$$),
  ('p29', 'praktijk', 29, $$Loskomen van aan de grond$$,                           $$Noodsituaties$$),
  ('p30', 'praktijk', 30, $$Verhelpen van storingen$$,                             $$Noodsituaties$$),
  ('p31', 'praktijk', 31, $$EHBO$$,                                                $$Noodsituaties$$),
  ('p32', 'praktijk', 32, $$Ankeren$$,                                             $$Overig$$),
  ('p33', 'praktijk', 33, $$Vaar- en jachtetiquette en zorg voor het schip$$,      $$Overig$$),
  ('t1',  'theorie',   1, $$Scheeps- en motortermen$$,                             null),
  ('t2',  'theorie',   2, $$Werking van de motor$$,                                null),
  ('t3',  'theorie',   3, $$Theoretische beginselen van het manoeuvreren op de motor$$, null),
  ('t4',  'theorie',   4, $$Theorie van alle genoemde praktijkmanoeuvres$$,        null),
  ('t5',  'theorie',   5, $$Reglementen$$,                                         null),
  ('t6',  'theorie',   6, $$Klein Vaarbewijs$$,
   $$Kennis van KVB I vanaf Schipper (CWO III); voor All Round Schipper (CWO IV) is het certificaat zelf vereist. Een Klein Vaarbewijs geeft vrijstelling van het theorie-examen.$$)
) as v(suffix, kind, position, title, detail)
where dp.code in ('sloep-1', 'sloep-2', 'sloep-3', 'sloep-4')
on conflict (code) do update set
  diploma_id = excluded.diploma_id,
  kind       = excluded.kind,
  position   = excluded.position,
  title      = excluded.title,
  detail     = excluded.detail;

-- ---------------------------------------------------------------- onderdelen
--
-- Eisen waar het handboek een opsomming achter zet: knopen, commando's,
-- termen, onderdelen van de boot. Die worden hier losse regels onder hun eis,
-- zodat een instructeur kan bijhouden dat de paalsteek zit en de mastworp nog
-- niet. Ze tellen niet mee in de voortgang — zie 012-onderdelen.sql.
--
-- De code van een onderdeel is die van zijn eis plus het nummer, dus
-- roeien-12.t1.3 is de derde knoop van Schiemanswerk bij Roeien I/II. Opnieuw
-- draaien werkt bij op die code, net als bij de eisen zelf.
--
-- Bewust níét uitgesplitst: de artikellijsten uit het Binnenvaartpolitie-
-- reglement. Vanaf Roeien III en Kielboot III zijn dat er tientallen, en een
-- scherm met tachtig vinkjes helpt niemand op een steiger. Die blijven één eis.

insert into requirements (diploma_id, parent_id, code, kind, position, title)
select p.diploma_id, p.id, p.code || '.' || v.position, p.kind, v.position, v.title
from (values

-- ---- Roeien I/II
('roeien-12.t1',  1, $$Twee halve steken, de eerste slippend$$),
('roeien-12.t1',  2, $$Achtknoop$$),
('roeien-12.t1',  3, $$Platte knoop$$),
('roeien-12.t1',  4, $$Mastworp, met slipsteek als borg$$),
('roeien-12.t1',  5, $$Een lijn opschieten$$),
('roeien-12.t1',  6, $$Een lijn beleggen op een kikker$$),

('roeien-12.p3',  1, $$Dollen ... in$$),
('roeien-12.p3',  2, $$Los ... voor en los ... achter$$),
('roeien-12.p3',  3, $$Op ... riemen$$),
('roeien-12.p3',  4, $$Haalt op ... gelijk$$),
('roeien-12.p3',  5, $$Stopt ... af$$),
('roeien-12.p3',  6, $$Strijkt ... gelijk$$),
('roeien-12.p3',  7, $$Zet ... af$$),
('roeien-12.p3',  8, $$Riemen ... lopen$$),
('roeien-12.p3',  9, $$Riemen ... geroeid$$),

('roeien-12.t2',  1, $$Slagroeier$$),
('roeien-12.t2',  2, $$Boegroeier$$),
('roeien-12.t2',  3, $$Midroeier$$),
('roeien-12.t2',  4, $$Roerganger$$),
('roeien-12.t2',  5, $$Haakvoor$$),
('roeien-12.t2',  6, $$Stuurboord en bakboord$$),
('roeien-12.t2',  7, $$Hogerwal en lagerwal$$),
('roeien-12.t2',  8, $$Bomen$$),
('roeien-12.t2',  9, $$Jagen$$),
('roeien-12.t2', 10, $$Wrikken$$),
('roeien-12.t2', 11, $$In de wind$$),
('roeien-12.t2', 12, $$Opschieten$$),
('roeien-12.t2', 13, $$Beleggen$$),

('roeien-12.t3',  1, $$Boeg$$),
('roeien-12.t3',  2, $$Hek$$),
('roeien-12.t3',  3, $$Dolboord$$),
('roeien-12.t3',  4, $$Doften$$),
('roeien-12.t3',  5, $$Roer$$),
('roeien-12.t3',  6, $$Helmstok$$),
('roeien-12.t3',  7, $$Stuurboord en bakboord$$),
('roeien-12.t3',  8, $$Roeiriem$$),
('roeien-12.t3',  9, $$Wrikriem$$),

-- ---- Roeien III
('roeien-3.p3',   1, $$Riemen ... op$$),
('roeien-3.p3',   2, $$Dollen ... in$$),
('roeien-3.p3',   3, $$Dollen ... richten$$),
('roeien-3.p3',   4, $$Riemen ... toe$$),
('roeien-3.p3',   5, $$Los ... voor en los ... achter$$),
('roeien-3.p3',   6, $$Op ... riemen$$),
('roeien-3.p3',   7, $$Haalt op ... gelijk$$),
('roeien-3.p3',   8, $$Stopt ... af$$),
('roeien-3.p3',   9, $$Strijkt ... gelijk$$),
('roeien-3.p3',  10, $$Zet ... af$$),
('roeien-3.p3',  11, $$Riemen ... lopen$$),
('roeien-3.p3',  12, $$Riemen ... over$$),
('roeien-3.p3',  13, $$Riemen ... geroeid$$),
('roeien-3.p3',  14, $$Stootwillen ... binnen of ... buiten$$),

('roeien-3.p19',  1, $$Twee halve steken, de eerste slippend$$),
('roeien-3.p19',  2, $$Achtknoop$$),
('roeien-3.p19',  3, $$Platte knoop$$),
('roeien-3.p19',  4, $$Mastworp, met slipsteek als borg$$),
('roeien-3.p19',  5, $$Schootsteek (enkel)$$),
('roeien-3.p19',  6, $$Paalsteek$$),
('roeien-3.p19',  7, $$Een lijn opschieten$$),
('roeien-3.p19',  8, $$Een lijn beleggen op een kikker$$),

('roeien-3.t1',   1, $$Twee halve steken, de eerste slippend$$),
('roeien-3.t1',   2, $$Achtknoop$$),
('roeien-3.t1',   3, $$Platte knoop$$),
('roeien-3.t1',   4, $$Mastworp, met slipsteek als borg$$),
('roeien-3.t1',   5, $$Schootsteek (enkel)$$),
('roeien-3.t1',   6, $$Paalsteek$$),
('roeien-3.t1',   7, $$Een lijn opschieten en beleggen op een kikker$$),
('roeien-3.t1',   8, $$Schavielen en de maatregelen daartegen$$),

('roeien-3.t2',   1, $$Slagroeier$$),
('roeien-3.t2',   2, $$Boegroeier$$),
('roeien-3.t2',   3, $$Roerganger$$),
('roeien-3.t2',   4, $$Haakvoor$$),
('roeien-3.t2',   5, $$Stuurboord en bakboord$$),
('roeien-3.t2',   6, $$Hogerwal en lagerwal$$),
('roeien-3.t2',   7, $$Loef en lij$$),
('roeien-3.t2',   8, $$Bomen$$),
('roeien-3.t2',   9, $$Jagen$$),
('roeien-3.t2',  10, $$Wrikken$$),
('roeien-3.t2',  11, $$In de wind$$),
('roeien-3.t2',  12, $$Opschieten$$),
('roeien-3.t2',  13, $$Beleggen$$),

('roeien-3.t3',   1, $$Boeg$$),
('roeien-3.t3',   2, $$Hek$$),
('roeien-3.t3',   3, $$Spiegel$$),
('roeien-3.t3',   4, $$Dolboord$$),
('roeien-3.t3',   5, $$Doften$$),
('roeien-3.t3',   6, $$Roer$$),
('roeien-3.t3',   7, $$Helmstok$$),
('roeien-3.t3',   8, $$Stuurboord en bakboord$$),
('roeien-3.t3',   9, $$Roeiriem$$),
('roeien-3.t3',  10, $$Wrikriem$$),
('roeien-3.t3',  11, $$Blad$$),
('roeien-3.t3',  12, $$Handvat$$),
('roeien-3.t3',  13, $$Dollen$$),
('roeien-3.t3',  14, $$Dolpot$$),
('roeien-3.t3',  15, $$Landvast$$),
('roeien-3.t3',  16, $$Hoosvat$$),

-- ---- Kielboot I
('kielboot-1.p6',  1, $$Klaar om te wenden$$),
('kielboot-1.p6',  2, $$Ree$$),
('kielboot-1.p6',  3, $$Fok bak$$),
('kielboot-1.p6',  4, $$Fok over$$),
('kielboot-1.p6',  5, $$Fok aan$$),

('kielboot-1.t1',  1, $$Achtknoop$$),
('kielboot-1.t1',  2, $$Twee halve steken, de eerste slippend$$),
('kielboot-1.t1',  3, $$Paalsteek$$),
('kielboot-1.t1',  4, $$Reefsteek (platte knoop)$$),
('kielboot-1.t1',  5, $$Beleggen op klamp, nagel of kikker$$),
('kielboot-1.t1',  6, $$Een tros opschieten$$),

('kielboot-1.t2',  1, $$Hogerwal en lagerwal$$),
('kielboot-1.t2',  2, $$Bakboord en stuurboord$$),
('kielboot-1.t2',  3, $$Hoge en lage zijde$$),
('kielboot-1.t2',  4, $$Loef- en lijzijde$$),
('kielboot-1.t2',  5, $$In de wind$$),
('kielboot-1.t2',  6, $$Aan de wind$$),
('kielboot-1.t2',  7, $$Halve wind$$),
('kielboot-1.t2',  8, $$Ruime wind$$),
('kielboot-1.t2',  9, $$Voor de wind$$),
('kielboot-1.t2', 10, $$Oploeven$$),
('kielboot-1.t2', 11, $$Afvallen$$),
('kielboot-1.t2', 12, $$Overstag gaan$$),
('kielboot-1.t2', 13, $$Gijpen$$),
('kielboot-1.t2', 14, $$Kruisrak$$),
('kielboot-1.t2', 15, $$Killen van het zeil$$),

-- ---- Kielboot II
('kielboot-2.p6',  1, $$Klaar om te wenden$$),
('kielboot-2.p6',  2, $$Ree$$),
('kielboot-2.p6',  3, $$Fok bak$$),
('kielboot-2.p6',  4, $$Fok over$$),
('kielboot-2.p6',  5, $$Fok aan$$),

('kielboot-2.t1',  1, $$Twee halve steken, de eerste slippend$$),
('kielboot-2.t1',  2, $$Achtknoop$$),
('kielboot-2.t1',  3, $$Paalsteek$$),
('kielboot-2.t1',  4, $$Platte knoop$$),
('kielboot-2.t1',  5, $$Mastworp, met slipsteek als borg$$),
('kielboot-2.t1',  6, $$Schootsteek (enkel)$$),
('kielboot-2.t1',  7, $$Een lijn opschieten$$),
('kielboot-2.t1',  8, $$Beleggen op een kikker$$),

('kielboot-2.t2',  1, $$De zeiltermen van Kielboot I$$),
('kielboot-2.t2',  2, $$Deinzen$$),
('kielboot-2.t2',  3, $$Opschieten$$),
('kielboot-2.t2',  4, $$Beleggen$$),

('kielboot-2.t3',  1, $$Blok$$),
('kielboot-2.t3',  2, $$Landvast$$),
('kielboot-2.t3',  3, $$Kiel$$),
('kielboot-2.t3',  4, $$Helmstok$$),
('kielboot-2.t3',  5, $$Roer$$),
('kielboot-2.t3',  6, $$Mast$$),
('kielboot-2.t3',  7, $$Giek$$),
('kielboot-2.t3',  8, $$Val$$),
('kielboot-2.t3',  9, $$Schoot$$),
('kielboot-2.t3', 10, $$Halshoek$$),
('kielboot-2.t3', 11, $$Schoothoek$$),
('kielboot-2.t3', 12, $$Grootzeil$$),
('kielboot-2.t3', 13, $$Fok$$),

-- ---- Kielboot III
('kielboot-3.p18', 1, $$Twee halve steken$$),
('kielboot-3.p18', 2, $$Slipsteek$$),
('kielboot-3.p18', 3, $$Achtknoop$$),
('kielboot-3.p18', 4, $$Platte knoop$$),
('kielboot-3.p18', 5, $$Schootsteek, enkel en dubbel$$),
('kielboot-3.p18', 6, $$Mastworp, op twee manieren$$),
('kielboot-3.p18', 7, $$Paalsteek$$),
('kielboot-3.p18', 8, $$Een tros opschieten$$),
('kielboot-3.p18', 9, $$Tros beleggen op een bolder$$),
('kielboot-3.p18', 10, $$Lijn beleggen op een klamp of nagel$$),

('kielboot-3.t1',  1, $$Twee halve steken, de eerste slippend$$),
('kielboot-3.t1',  2, $$Achtknoop$$),
('kielboot-3.t1',  3, $$Paalsteek$$),
('kielboot-3.t1',  4, $$Platte knoop$$),
('kielboot-3.t1',  5, $$Mastworp, op twee manieren$$),
('kielboot-3.t1',  6, $$Schootsteek, enkel en dubbel$$),
('kielboot-3.t1',  7, $$Opschieten en beleggen, op kikker en bolder$$),
('kielboot-3.t1',  8, $$Verschil tussen geslagen en gevlochten touwwerk$$),
('kielboot-3.t1',  9, $$Welk touw waarvoor: landvast, val, schoot, sleeplijn, ankerlijn$$),
('kielboot-3.t1', 10, $$Schavielen en de maatregelen daartegen$$),

('kielboot-3.t2',  1, $$De zeiltermen van Kielboot II$$),
('kielboot-3.t2',  2, $$Bovenlangs en onderlangs$$),
('kielboot-3.t2',  3, $$Dwarspeiling$$),
('kielboot-3.t2',  4, $$Bezeild$$),
('kielboot-3.t2',  5, $$Binnen de wind$$),
('kielboot-3.t2',  6, $$Korte slag en lange slag$$),
('kielboot-3.t2',  7, $$Opschieter$$),
('kielboot-3.t2',  8, $$Zuigen en duiken$$),
('kielboot-3.t2',  9, $$Planeren$$),
('kielboot-3.t2', 10, $$Volvallen$$),
('kielboot-3.t2', 11, $$Verhalen$$),
('kielboot-3.t2', 12, $$Verlijeren en drift$$),
('kielboot-3.t2', 13, $$Bijliggen$$),
('kielboot-3.t2', 14, $$Bakhouden$$),

('kielboot-3.t3',  1, $$Voorsteven$$),
('kielboot-3.t3',  2, $$Spiegel$$),
('kielboot-3.t3',  3, $$Sluiting en kous$$),
('kielboot-3.t3',  4, $$Blok$$),
('kielboot-3.t3',  5, $$Stootkussen$$),
('kielboot-3.t3',  6, $$Hoosvat$$),
('kielboot-3.t3',  7, $$Landvast$$),
('kielboot-3.t3',  8, $$Kiel$$),
('kielboot-3.t3',  9, $$Helmstok$$),
('kielboot-3.t3', 10, $$Roer en roerblad$$),
('kielboot-3.t3', 11, $$Mast$$),
('kielboot-3.t3', 12, $$Giek$$),
('kielboot-3.t3', 13, $$Val$$),
('kielboot-3.t3', 14, $$Halstalie$$),
('kielboot-3.t3', 15, $$Schoot$$),
('kielboot-3.t3', 16, $$Voorlijk, achterlijk en onderlijk$$),
('kielboot-3.t3', 17, $$Halshoek en schoothoek$$),
('kielboot-3.t3', 18, $$Grootzeil$$),
('kielboot-3.t3', 19, $$Fok$$),

-- ---- Kielboot IV
('kielboot-4.p20', 1, $$De knopen en steken van Kielboot III$$),
('kielboot-4.p20', 2, $$Splits in driestrengs touwwerk$$),
('kielboot-4.p20', 3, $$Benaaide takeling$$),

('kielboot-4.t11', 1, $$Schacht$$),
('kielboot-4.t11', 2, $$Stok$$),
('kielboot-4.t11', 3, $$Kruis$$),
('kielboot-4.t11', 4, $$Armen en vloeien$$),
('kielboot-4.t11', 5, $$Verschil lichtgewicht- en volgewichtanker$$),
('kielboot-4.t11', 6, $$Hollands stokanker$$),
('kielboot-4.t11', 7, $$Dreg en klapdreg$$),
('kielboot-4.t11', 8, $$Danforth-anker$$),
('kielboot-4.t11', 9, $$Ploegschaaranker$$),

-- ---- Buitenboordmotor I/II
('bbm-12.p15', 1, $$Platte knoop$$),
('bbm-12.p15', 2, $$Paalsteek$$),
('bbm-12.p15', 3, $$Halve steek$$),
('bbm-12.p15', 4, $$Mastworp$$),
('bbm-12.p15', 5, $$Een lijn opschieten$$),
('bbm-12.p15', 6, $$Beleggen op een kikker of bolder$$),

('bbm-12.t1',  1, $$Boeg$$),
('bbm-12.t1',  2, $$Stuurboord en bakboord$$),
('bbm-12.t1',  3, $$Steven$$),
('bbm-12.t1',  4, $$Spanten$$),
('bbm-12.t1',  5, $$Spiegel$$),
('bbm-12.t1',  6, $$Motorsteun$$),
('bbm-12.t1',  7, $$Vrijboord$$),
('bbm-12.t1',  8, $$Bougie$$),
('bbm-12.t1',  9, $$Brandstofslang$$),
('bbm-12.t1', 10, $$Carburator$$),
('bbm-12.t1', 11, $$Koelwateruitlaat$$),
('bbm-12.t1', 12, $$Gas- en chokehandel$$),

-- ---- Buitenboordmotor III
('bbm-3.t1',   1, $$De onderdelen van Buitenboordmotor I/II$$),
('bbm-3.t1',   2, $$Bougie$$),
('bbm-3.t1',   3, $$Brandstofleiding$$),
('bbm-3.t1',   4, $$Koelwateruitlaat$$),
('bbm-3.t1',   5, $$Breekpen$$),
('bbm-3.t1',   6, $$Gas- en chokehandel$$),
('bbm-3.t1',   7, $$Startkoord$$),

('bbm-3.p14',  1, $$Bougie schoonmaken en afstellen$$),
('bbm-3.p14',  2, $$Breekpen vervangen$$),
('bbm-3.p14',  3, $$Brandstofleiding controleren$$),
('bbm-3.p14',  4, $$Koelwaterproblemen oplossen$$)

) as v(parent, position, title)
join requirements p on p.code = v.parent
on conflict (code) do update set
  diploma_id = excluded.diploma_id,
  parent_id  = excluded.parent_id,
  kind       = excluded.kind,
  position   = excluded.position,
  title      = excluded.title;

-- ---------------------------------------------------------------- insignes
--
-- Het insigne Bemanningslid van Scouting Nederland, uit het activiteitengebied
-- Uitdagende Scoutingtechnieken. Landelijk vastgesteld, net als de CWO-eisen,
-- dus het hoort hier en niet in een eigen lijst van één groep.
--
-- Het PDF zet de eisen in een tabel van drie kolommen — niveau 1, 2 en 3 — met
-- vijf thema's onder elkaar: De basis, Kennis van je schip, Vaardigheden,
-- Veiligheid, Spic en span. Elk niveau is hier één lijst, en het thema staat
-- vooraan in de titel, zodat je op het scherm ziet waar een eis bij hoort.
--
-- Praktijk of theorie is een keuze van ons, niet van het boekje: dat kent het
-- onderscheid niet. Wat je laat zien of doet is praktijk; wat je uitlegt,
-- benoemt of kent is theorie.
--
-- Bron: Insigne Bemanningslid, Scouting Nederland (definitieve versie).

insert into disciplines (code, name, subtitle, sort_order) values
  ('insigne', $$Insignes$$, $$Uitdagende Scoutingtechnieken$$, 5)
on conflict (code) do update set
  name       = excluded.name,
  subtitle   = excluded.subtitle,
  sort_order = excluded.sort_order;

insert into diplomas (discipline_id, code, kind, name, level_label, summary, sort_order, source)
select d.id, v.code, 'insigne'::list_kind, v.name, v.level_label, v.summary, v.sort_order, v.source
from (values
  ('insigne', 'bml-1', $$Bemanningslid niveau 1$$, $$Niveau 1$$,
   $$Kennismaken met varen op een lelievlet: de onderdelen en termen van het schip, de eerste knopen, veilig aan boord bewegen en meehelpen aan boord.$$,
   1, $$Insigne Bemanningslid, Scouting Nederland — niveau 1$$),

  ('insigne', 'bml-2', $$Bemanningslid niveau 2$$, $$Niveau 2$$,
   $$Verder op de lelievlet: aanleggen, ankeren en slepen, weten wat te doen als de vlet omslaat, en een basis in roeien en zeilen die je met een watersportdiploma of insigne aantoont.$$,
   2, $$Insigne Bemanningslid, Scouting Nederland — niveau 2$$),

  ('insigne', 'bml-3', $$Bemanningslid niveau 3$$, $$Niveau 3$$,
   $$Bemanningslid op een sleper, motorschip of wachtschip: het schip vaarklaar maken, schutten, slepen, communicatiemiddelen en onderhoud aan schip en motor. Sluit aan op het watersportdiploma sloep- en motorvletvaren.$$,
   3, $$Insigne Bemanningslid, Scouting Nederland — niveau 3$$)
) as v(discipline, code, name, level_label, summary, sort_order, source)
join disciplines d on d.code = v.discipline
on conflict (code) do update set
  discipline_id = excluded.discipline_id,
  kind          = excluded.kind,
  name          = excluded.name,
  level_label   = excluded.level_label,
  summary       = excluded.summary,
  sort_order    = excluded.sort_order,
  source        = excluded.source;

insert into requirements (diploma_id, code, kind, position, title, detail)
select dp.id, v.code, v.kind::requirement_kind, v.position, v.title, v.detail
from (values

-- ---------------- Bemanningslid niveau 1 — praktijk
('bml-1', 'bml-1.p1', 'praktijk', 1, $$De basis: zwemmen$$,
 $$Toon aan dat je kunt zwemmen, bijvoorbeeld door je zwemdiploma A te laten zien.$$),
('bml-1', 'bml-1.p2', 'praktijk', 2, $$De basis: een rechte koers varen$$,
 $$Je weet hoe het roer werkt. Vaar een rechte koers op een vast punt. Je hoeft hierbij niet de zeilen of het zwaard te bedienen.$$),
('bml-1', 'bml-1.p3', 'praktijk', 3, $$Vaardigheden: lijnen opbergen$$,
 $$Laat zien hoe je de lijnen netjes opbergt.$$),
('bml-1', 'bml-1.p4', 'praktijk', 4, $$Veiligheid: bukken bij een gijp$$,
 $$Oefen het op tijd bukken bij een gecontroleerde gijp.$$),
('bml-1', 'bml-1.p5', 'praktijk', 5, $$Veiligheid: veilig aan boord bewegen$$,
 $$Sta en loop niet in de boot en houd je handen binnenboord tijdens het varen.$$),
('bml-1', 'bml-1.p6', 'praktijk', 6, $$Spic en span: bagage opbergen$$,
 $$Laat zien hoe je bagage aan boord netjes en watervast opbergt.$$),
('bml-1', 'bml-1.p7', 'praktijk', 7, $$Spic en span: aanleggen op een kikker$$,
 $$Leg een boot aan en leg een landvast aan een kikker.$$),
('bml-1', 'bml-1.p8', 'praktijk', 8, $$Spic en span: een sleeplijn aanpakken$$,
 $$Pak een sleeplijn aan op een klein zeilbootje, zoals een optimist, en maak deze goed vast.$$),

-- ---------------- Bemanningslid niveau 1 — theorie
('bml-1', 'bml-1.t1', 'theorie', 1, $$Kennis van je schip: vijftien onderdelen van een vlet$$,
 $$Herken de vijftien belangrijkste onderdelen van een vlet.$$),
('bml-1', 'bml-1.t2', 'theorie', 2, $$Kennis van je schip: vijftien vaartermen$$,
 $$Leg uit wat deze vijftien belangrijke vaartermen betekenen.$$),
('bml-1', 'bml-1.t3', 'theorie', 3, $$Vaardigheden: knopen en hun toepassing$$,
 $$Leg uit wanneer je deze knopen toepast.$$),
('bml-1', 'bml-1.t4', 'theorie', 4, $$Veiligheid: kleding en schoeisel$$,
 $$Leg uit wat goede kleding en goed schoeisel is aan boord van een lelievlet.$$),
('bml-1', 'bml-1.t5', 'theorie', 5, $$Veiligheid: het reddingsvest$$,
 $$Vertel wat de regels zijn voor het dragen van een reddingsvest, zoals die in de Nautisch Technische Richtlijnen (NTR) staan.$$),
('bml-1', 'bml-1.t6', 'theorie', 6, $$Veiligheid: goed zeemanschap$$,
 $$Benoem de vaarregel voor goed zeemanschap.$$),
('bml-1', 'bml-1.t7', 'theorie', 7, $$Veiligheid: omgaan met de natuur$$,
 $$Benoem hoe je op een goede manier met de natuur — planten, dieren en afval — op en rond het water omgaat.$$),

-- ---------------- Bemanningslid niveau 2 — praktijk
('bml-2', 'bml-2.p1', 'praktijk', 1, $$De basis: roeien en zeilen aantonen$$,
 $$Voldoe aan één eis uit elke groep. Groep 1, roeien: het insigne Varen op Spierkracht niveau 1 (variant roeien), of het watersportdiploma Roeien (CWO Roeien I/II). Groep 2, zeilen: het watersportdiploma Jeugdzeilen (CWO Jeugdzeilen), of het watersportdiploma Kielboot (CWO Kielboot I).$$),
('bml-2', 'bml-2.p2', 'praktijk', 2, $$Vaardigheden: aanleggen met landvasten$$,
 $$Laat zien hoe je het schip aanlegt en op welke manier je de landvasten gebruikt. Voer dit uit bij het aanleggen aan een vaste wal, een steiger of een brug.$$),
('bml-2', 'bml-2.p3', 'praktijk', 3, $$Vaardigheden: ankeren$$,
 $$Leg het anker goed klaar, werp het correct uit, controleer of het goed ligt en maak het weer los.$$),
('bml-2', 'bml-2.p4', 'praktijk', 4, $$Vaardigheden: veilig slepen$$,
 $$Hanteer de basisveiligheidsregels tijdens het slepen, volgens de NTR en de regels van je groep.$$),
('bml-2', 'bml-2.p5', 'praktijk', 5, $$Vaardigheden: een sleeplijn aanpakken$$,
 $$Pak een sleeplijn aan en leg hem vast.$$),
('bml-2', 'bml-2.p6', 'praktijk', 6, $$Vaardigheden: het zwaard tijdens het slepen$$,
 $$Toon aan hoe je het zwaard van een lelievlet gebruikt tijdens het slepen.$$),
('bml-2', 'bml-2.p7', 'praktijk', 7, $$Vaardigheden: afremmen met een puts$$,
 $$Laat zien hoe je een puts of emmer gebruikt om af te remmen tijdens het slepen.$$),
('bml-2', 'bml-2.p8', 'praktijk', 8, $$Spic en span: zeilen uithangen$$,
 $$Laat zien hoe je zeilen uithangt na het varen, als ze nat zijn geworden.$$),
('bml-2', 'bml-2.p9', 'praktijk', 9, $$Spic en span: lijnen uitspoelen$$,
 $$Laat zien hoe je lijnen uitspoelt, nadat er bijvoorbeeld zand in is gekomen.$$),
('bml-2', 'bml-2.p10', 'praktijk', 10, $$Spic en span: groot onderhoud van de vlet$$,
 $$Voer minimaal twee onderhoudstaken uit tijdens het groot onderhoud van de lelievlet, zoals schuren of schilderen. Zorg dat je je afval netjes opruimt en scheidt.$$),

-- ---------------- Bemanningslid niveau 2 — theorie
('bml-2', 'bml-2.t1', 'theorie', 1, $$De basis: Beaufort en de zeilkoersen$$,
 $$Je kent de schaal van Beaufort (windkracht) en de zeilkoersen van een lelievlet.$$),
('bml-2', 'bml-2.t2', 'theorie', 2, $$Kennis van je schip: zwemvest, reddingsvest en self-inflatable$$,
 $$Leg uit wat de verschillen zijn tussen zwemvesten, reddingsvesten en self-inflatables.$$),
('bml-2', 'bml-2.t3', 'theorie', 3, $$Kennis van je schip: vanuit de kuip werken$$,
 $$Leg uit hoe je veilig vanuit de kuip kunt werken.$$),
('bml-2', 'bml-2.t4', 'theorie', 4, $$Kennis van je schip: waar je wel en niet zwemt$$,
 $$Vertel waar je, in jouw vaaromgeving, wel en niet veilig kunt of mag zwemmen.$$),
('bml-2', 'bml-2.t5', 'theorie', 5, $$Kennis van je schip: zwanen en ganzen$$,
 $$Leg uit wat de risico's zijn als je op het water zwanen of ganzen tegenkomt.$$),
('bml-2', 'bml-2.t6', 'theorie', 6, $$Veiligheid: de vlet is omgeslagen$$,
 $$Leg uit wat je moet doen als de lelievlet omgeslagen is.$$),

-- ---------------- Bemanningslid niveau 3 — praktijk
('bml-3', 'bml-3.p1', 'praktijk', 1, $$De basis: het schip klaarmaken om uit te varen$$,
 $$Help het schip klaar te maken om uit te varen: zorg dat alle materialen compleet zijn, controleer de motor en maak hem klaar, en controleer dat alle vereiste veiligheidsmiddelen aan boord zijn. Met schip wordt op dit niveau een sleper, motorschip of wachtschip bedoeld.$$),
('bml-3', 'bml-3.p2', 'praktijk', 2, $$De basis: dagelijks onderhoud aan de motor$$,
 $$Laat zien hoe je klein of dagelijks onderhoud aan de motor van het schip uitvoert.$$),
('bml-3', 'bml-3.p3', 'praktijk', 3, $$Kennis van je schip: een veiligheidsplattegrond$$,
 $$Maak een veiligheidsplattegrond van het schip.$$),
('bml-3', 'bml-3.p4', 'praktijk', 4, $$Vaardigheden: schutten in een sluis$$,
 $$Leg een schip vast in een sluis en laat daarbij zien wat je met de lijnen moet doen.$$),
('bml-3', 'bml-3.p5', 'praktijk', 5, $$Vaardigheden: een bolder beleggen$$,
 $$Beleg stilstaand een bolder.$$),
('bml-3', 'bml-3.p6', 'praktijk', 6, $$Vaardigheden: ankeren$$,
 $$Leg het anker goed klaar, werp het correct uit, controleer of het goed ligt en maak het weer los.$$),
('bml-3', 'bml-3.p7', 'praktijk', 7, $$Vaardigheden: sleepopstellingen$$,
 $$Noem twee soorten sleepopstellingen en coördineer ze.$$),
('bml-3', 'bml-3.p8', 'praktijk', 8, $$Spic en span: groot onderhoud aan het schip$$,
 $$Voer minimaal twee onderhoudstaken uit tijdens het groot onderhoud van het schip. Weet welke onderhoudsmiddelen duurzamer zijn en kies, binnen de mogelijkheden van je groep, voor de duurzaamste optie.$$),
('bml-3', 'bml-3.p9', 'praktijk', 9, $$Spic en span: onderhoud aan de motor$$,
 $$Assisteer bij groot onderhoud aan de motor.$$),

-- ---------------- Bemanningslid niveau 3 — theorie
('bml-3', 'bml-3.t1', 'theorie', 1, $$Kennis van je schip: de veiligheidsmiddelen$$,
 $$Vertel waar alle veiligheidsmiddelen aan boord te vinden zijn en hoe je ze kunt gebruiken.$$),
('bml-3', 'bml-3.t2', 'theorie', 2, $$Vaardigheden: typen sleeplijnen$$,
 $$Noem twee typen sleeplijnen.$$),
('bml-3', 'bml-3.t3', 'theorie', 3, $$Veiligheid: communicatiemiddelen op het water$$,
 $$Weet hoe je communicatiemiddelen op het water correct gebruikt. PMR- en LPD-portofoons en mobiele telefoons lopen over open netwerken: storing is mogelijk en de hulpdiensten luisteren niet mee. Voor een marifoon moet je gecertificeerd zijn.$$)

) as v(diploma, code, kind, position, title, detail)
join diplomas dp on dp.code = v.diploma
on conflict (code) do update set
  diploma_id = excluded.diploma_id,
  kind       = excluded.kind,
  position   = excluded.position,
  title      = excluded.title,
  detail     = excluded.detail;

-- De opsommingen achter een eis, als losse onderdelen.
insert into requirements (diploma_id, parent_id, code, kind, position, title)
select p.diploma_id, p.id, p.code || '.' || v.position, p.kind, v.position, v.title
from (values

-- ---- De vijftien onderdelen van een vlet
('bml-1.t1',  1, $$Voordek$$),
('bml-1.t1',  2, $$Achterdek$$),
('bml-1.t1',  3, $$Roer$$),
('bml-1.t1',  4, $$Doft$$),
('bml-1.t1',  5, $$Vlonder of buikdenning$$),
('bml-1.t1',  6, $$Zijstag$$),
('bml-1.t1',  7, $$Voorstag$$),
('bml-1.t1',  8, $$Mast$$),
('bml-1.t1',  9, $$Fok$$),
('bml-1.t1', 10, $$Grootzeil$$),
('bml-1.t1', 11, $$Anker$$),
('bml-1.t1', 12, $$Dol$$),
('bml-1.t1', 13, $$Riem$$),
('bml-1.t1', 14, $$Wrikriem$$),
('bml-1.t1', 15, $$Hoosblik$$),

-- ---- De vijftien vaartermen
('bml-1.t2',  1, $$Bakboord$$),
('bml-1.t2',  2, $$Stuurboord$$),
('bml-1.t2',  3, $$Overstag$$),
('bml-1.t2',  4, $$Gijp$$),
('bml-1.t2',  5, $$Hogerwal$$),
('bml-1.t2',  6, $$Lagerwal$$),
('bml-1.t2',  7, $$Roeien$$),
('bml-1.t2',  8, $$Zeilen$$),
('bml-1.t2',  9, $$Wrikken$$),
('bml-1.t2', 10, $$Oploeven$$),
('bml-1.t2', 11, $$Afvallen$$),
('bml-1.t2', 12, $$Noord$$),
('bml-1.t2', 13, $$Oost$$),
('bml-1.t2', 14, $$Zuid$$),
('bml-1.t2', 15, $$West$$),

-- ---- De knopen van niveau 1
('bml-1.t3',  1, $$Achtknoop$$),
('bml-1.t3',  2, $$Mastworp$$),
('bml-1.t3',  3, $$Paalsteek$$),
('bml-1.t3',  4, $$Kikker beleggen$$),
('bml-1.t3',  5, $$Halve steek$$),

-- ---- Als de vlet omslaat
('bml-2.t6',  1, $$Veiligheidsmaatregelen van en voor de bemanningsleden$$),
('bml-2.t6',  2, $$Het materiaal veiligstellen$$),
('bml-2.t6',  3, $$De hulpdiensten alarmeren$$),

-- ---- Communicatiemiddelen
('bml-3.t3',  1, $$PMR- of LPD-portofoon$$),
('bml-3.t3',  2, $$Mobiele telefoon$$),
('bml-3.t3',  3, $$Basiskennis marifoon$$),
('bml-3.t3',  4, $$SOS- en noodsignalen$$)

) as v(parent, position, title)
join requirements p on p.code = v.parent
on conflict (code) do update set
  diploma_id = excluded.diploma_id,
  parent_id  = excluded.parent_id,
  kind       = excluded.kind,
  position   = excluded.position,
  title      = excluded.title;

