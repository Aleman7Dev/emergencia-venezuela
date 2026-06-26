-- ============================================================================
-- Emergencia Sísmica · Venezuela — Configuración recomendada de Supabase
-- Ejecuta esto en: Supabase → SQL Editor → New query → Run
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) "Marcar despejada" (vialidad) que persista entre dispositivos
-- ----------------------------------------------------------------------------
-- El cliente NO actualiza la tabla directamente (sería inseguro permitir UPDATE
-- libre con la clave anónima). En su lugar llama a esta función, que solo puede
-- poner una vía (type='road') en estado "despejada" (RS:open). Nada más.
create or replace function public.mark_road_open(rid text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.reports
     set need = case
       when need ~ 'RS:(closed|partial|moto|foot|open)'
         then regexp_replace(need, 'RS:(closed|partial|moto|foot|open)', 'RS:open')
       else coalesce(need, '') || ' RS:open'
     end
   where id::text = rid
     and type = 'road';
$$;

grant execute on function public.mark_road_open(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 1.bis) Crear reportes SOLO por función validada (cierra el hueco de seguridad)
-- ----------------------------------------------------------------------------
-- Hoy la app crea reportes con un POST directo a /rest/v1/reports usando la clave
-- pública (anon) que está en el HTML. Eso permite que CUALQUIERA inserte o falsee
-- reportes en masa. Esta función valida en el servidor y es el único camino de
-- inserción una vez que revoques el INSERT anónimo (paso c). La app y el importador
-- ya usan esta función primero y caen al POST directo solo mientras no exista (404),
-- así que puedes crearla sin romper nada y revocar el INSERT al final.
create or replace function public.crear_reporte(
  p_type text, p_title text, p_loc text, p_need text,
  p_lon double precision, p_lat double precision, p_precision text
) returns public.reports
language plpgsql security definer set search_path = public as $$
declare r public.reports;
begin
  if p_type is null or p_type not in
     ('crit','build','escombros','road','miss','hosp','acopio','aid','dark','water','volunteer','safe') then
    raise exception 'tipo invalido';
  end if;
  if p_title is null or length(btrim(p_title)) = 0 then raise exception 'titulo requerido'; end if;
  if p_lon is null or p_lat is null
     or p_lon not between -74 and -59 or p_lat not between 0 and 16 then
    raise exception 'coordenadas fuera de rango (Venezuela)';
  end if;
  insert into public.reports(type, title, loc, need, lon, lat, precision, status)
  values (p_type, left(btrim(p_title),160), left(coalesce(p_loc,''),300),
          left(coalesce(p_need,''),2000), p_lon, p_lat, coalesce(p_precision,'approx'), 'activo')
  returning * into r;
  return r;
end $$;
grant execute on function public.crear_reporte(text,text,text,text,double precision,double precision,text)
  to anon, authenticated;

-- c) AL FINAL (después de desplegar la app nueva y probar que crear un reporte funciona,
--    y de haber aplicado la sección 2 — CHECK/ENUM con 'escombros' y 'volunteer' — para que
--    crear_reporte no rechace tipos válidos):
--    cierra la inserción directa con la clave pública. Mira el nombre real de la
--    política de INSERT en Database -> reports -> Policies y elimínala:
-- drop policy if exists "anon inserta reports" on public.reports;   -- ajusta el nombre
--    (o, si el INSERT no se controla por política sino por permiso de tabla:)
-- revoke insert on public.reports from anon;
--    Tras esto, SOLO crear_reporte() puede insertar (corre como definer y no pasa por RLS).
--    La LECTURA (select) sigue pública; no la toques.

-- ----------------------------------------------------------------------------
-- 2) Permitir el tipo de reporte "volunteer" (buscadores voluntarios)
-- ----------------------------------------------------------------------------
-- Solo es necesario SI la columna "type" tiene una restricción CHECK o un ENUM
-- que limite los valores. Si "type" es texto libre, NO hace falta nada.
--
-- a) Si usas un CHECK constraint, recréalo incluyendo 'volunteer' y 'road':
--    (ajusta el nombre del constraint; míralo en Database → Tables → reports)
--
-- alter table public.reports drop constraint if exists reports_type_check;
-- alter table public.reports add constraint reports_type_check
--   check (type in ('crit','build','escombros','road','miss','hosp','acopio','aid',
--                   'dark','water','volunteer','safe'));
--
-- b) Si "type" es un ENUM de Postgres, añade el valor:
-- alter type report_type add value if not exists 'volunteer';
-- alter type report_type add value if not exists 'escombros';

-- ----------------------------------------------------------------------------
-- 3) Fotos de personas (bucket de Storage)  ← NECESARIO para la foto del reporte
-- ----------------------------------------------------------------------------
-- La app sube una foto (reducida y sin metadatos GPS) al bucket público "fotos"
-- y guarda su URL dentro del reporte. Sin este bucket + permiso, la foto no se
-- sube (el reporte igual se publica, pero sin imagen).
--
-- a) Crear el bucket "fotos" público, con límite de 5 MB y solo imágenes:
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- b) Permitir SUBIR (insert) al bucket "fotos" con la clave pública (rol anon).
--    La LECTURA ya es pública porque el bucket es público.
drop policy if exists "anon sube fotos" on storage.objects;
create policy "anon sube fotos"
  on storage.objects for insert
  to anon, authenticated
  with check ( bucket_id = 'fotos' );

-- ----------------------------------------------------------------------------
-- 4) Muro de apoyo / oraciones (sección "Apoyo")  ← para que los mensajes se
--    compartan entre dispositivos. Sin esto, la sección funciona igual pero los
--    mensajes quedan solo en el navegador de quien los escribe.
-- ----------------------------------------------------------------------------
create table if not exists public.mensajes (
  id          bigint generated by default as identity primary key,
  nombre      text,
  mensaje     text not null check (char_length(mensaje) between 1 and 280),
  created_at  timestamptz not null default now()
);
alter table public.mensajes enable row level security;

drop policy if exists "lee mensajes" on public.mensajes;
create policy "lee mensajes" on public.mensajes
  for select to anon, authenticated using (true);

drop policy if exists "inserta mensajes" on public.mensajes;
create policy "inserta mensajes" on public.mensajes
  for insert to anon, authenticated
  with check (char_length(mensaje) between 1 and 280 and char_length(coalesce(nombre,'')) <= 40);

-- ----------------------------------------------------------------------------
-- 5) Contador de "personas orando por Venezuela" (botón de oración en portada)
--    Es un contador COMPARTIDO que arranca en 170 y solo sube de 1 en 1 al tocar
--    el botón. Independiente del nº de mensajes. Sin esto, cada dispositivo lleva
--    su propio conteo local (igual funciona, pero no se comparte).
-- ----------------------------------------------------------------------------
create table if not exists public.oraciones (
  id    int primary key,
  total bigint not null default 0
);
insert into public.oraciones (id, total) values (1, 170)
  on conflict (id) do nothing;

alter table public.oraciones enable row level security;
drop policy if exists "lee oraciones" on public.oraciones;
create policy "lee oraciones" on public.oraciones
  for select to anon, authenticated using (true);

-- Solo se puede sumar +1 a través de esta función (no UPDATE libre con la clave pública).
create or replace function public.orar()
  returns bigint language sql security definer set search_path = public as $$
  update public.oraciones set total = total + 1 where id = 1 returning total;
$$;
grant execute on function public.orar() to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 6) Contador de esperanza (sección "Apoyo")
-- ----------------------------------------------------------------------------
-- La cifra la calcula la función serverless /api/esperanza (en Vercel), así:
--      total = localizados en el directorio aliado (desaparecidosterremotovenezuela.com)
--            + personas confirmadas como encontradas EN NUESTRO sitio.
-- "Confirmadas aquí" = reportes 'miss' retirados por confirmación (status='atendido')
-- o reportes 'safe'. NO requiere cambios de esquema y funciona tal cual.
--
-- Para que los reportes ya confirmados (status='atendido') SÍ se cuenten con la
-- clave pública, la política de lectura de "reports" debe permitir verlos. Si tu
-- política de SELECT filtra solo status='activo', los 'atendido' no se contarán.
-- Los reportes ciudadanos son públicos, así que puedes permitir su lectura:
--
-- drop policy if exists "lee reports" on public.reports;
-- create policy "lee reports" on public.reports
--   for select to anon, authenticated using (true);
--
-- (La app igualmente solo PINTA en el mapa los status='activo'; esto solo habilita
--  el conteo de los ya encontrados para el contador de esperanza.)

-- ----------------------------------------------------------------------------
-- Notas
-- ----------------------------------------------------------------------------
-- · El cruce hospital ↔ desaparecidos (cédula/nombre) NO requiere cambios de
--   esquema: la app guarda el hash de la cédula dentro del texto del reporte.
-- · Si tu columna "id" es uuid o bigint, la función de arriba ya funciona
--   porque compara id::text = rid.
