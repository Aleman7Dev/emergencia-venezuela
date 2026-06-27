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
-- 7) Solicitudes de ayuda (tablón de necesidades de la respuesta)  ← NECESARIO
--    para el módulo "Solicitudes" (vista principal). Sin esta tabla, la sección
--    se ve vacía pero no rompe nada.
-- ----------------------------------------------------------------------------
create table if not exists public.solicitudes (
  id           bigint generated by default as identity primary key,
  tipo         text not null default 'solicitud',  -- solicitud (pide) | ofrecimiento (ofrece)
  kind         text not null,    -- voluntarios|agua|alimentos|herramientas|insumos|insumos_medicos|transporte|refugio
  titulo       text not null,
  detalle      text,
  sector       text,             -- zona aproximada (municipio/sector); NO direcciones exactas
  contacto     text,             -- cómo contactar (público; idealmente el de la organización)
  organizacion text,             -- si la publica una organización (badge "verificado por")
  prioridad    text not null default 'normal',  -- normal|urgente
  estado       text not null default 'abierta', -- abierta|en_proceso|cumplida|cancelada
  owner_token  text,             -- token anónimo del creador para gestionar el estado (no se publica)
  lon double precision, lat double precision,    -- aprox (centro del sector), opcional
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '10 days'
);
-- Si la tabla ya existía sin estas columnas, añádelas:
alter table public.solicitudes add column if not exists tipo text not null default 'solicitud';
alter table public.solicitudes add column if not exists verificada boolean not null default false;
alter table public.solicitudes enable row level security;

-- Lectura pública SOLO de las vigentes y no canceladas. NUNCA selecciones owner_token
-- desde el cliente (la app pide columnas explícitas sin owner_token).
drop policy if exists "lee solicitudes" on public.solicitudes;
create policy "lee solicitudes" on public.solicitudes
  for select to anon, authenticated using (estado <> 'cancelada' and expires_at > now());

-- Códigos de organizaciones verificadas (Cruz Roja, Protección Civil, parroquias…).
-- El administrador reparte un código secreto a cada aliado y lo registra aquí. Quien
-- publica con un código válido obtiene el badge "Verificada" y el nombre oficial.
-- NO se lee desde el cliente (RLS sin política de SELECT → solo lo usan las funciones).
create table if not exists public.org_codes (
  code         text primary key,
  organizacion text not null,
  activo       boolean not null default true
);
alter table public.org_codes enable row level security;   -- sin política => el cliente no lo lee
-- Ejemplo (descomenta y ajusta para dar de alta aliados):
-- insert into public.org_codes(code, organizacion) values
--   ('CRUZROJA-2026', 'Cruz Roja Venezolana'),
--   ('PCIVIL-LAGUAIRA', 'Protección Civil La Guaira')
-- on conflict (code) do update set organizacion = excluded.organizacion, activo = true;

-- Crear solo por función validada (no INSERT directo con la clave pública).
-- Maneja solicitudes (pide) y ofrecimientos (ofrece) según p_tipo. Si p_codigo coincide
-- con un código activo de org_codes, marca la publicación como verificada y usa el
-- nombre oficial de la organización. Se elimina la versión previa para evitar sobrecargas.
drop function if exists public.crear_solicitud(text,text,text,text,text,text,text,text,double precision,double precision);
drop function if exists public.crear_solicitud(text,text,text,text,text,text,text,text,text,double precision,double precision);
create or replace function public.crear_solicitud(
  p_tipo text, p_kind text, p_titulo text, p_detalle text, p_sector text,
  p_contacto text, p_organizacion text, p_prioridad text, p_owner text,
  p_lon double precision, p_lat double precision, p_codigo text default null
) returns public.solicitudes
language plpgsql security definer set search_path = public as $$
declare s public.solicitudes; v_org text; v_verif boolean := false;
begin
  if p_kind is null or p_kind not in
     ('voluntarios','agua','alimentos','herramientas','insumos','insumos_medicos','transporte','refugio') then
    raise exception 'categoria invalida';
  end if;
  if p_titulo is null or length(btrim(p_titulo)) < 3 then raise exception 'titulo requerido'; end if;
  if nullif(btrim(coalesce(p_codigo,'')),'') is not null then
    select organizacion into v_org from public.org_codes where code = btrim(p_codigo) and activo;
    if found then v_verif := true; end if;
  end if;
  insert into public.solicitudes(tipo,kind,titulo,detalle,sector,contacto,organizacion,prioridad,estado,owner_token,lon,lat,verificada)
  values (case when p_tipo='ofrecimiento' then 'ofrecimiento' else 'solicitud' end,
          p_kind, left(btrim(p_titulo),140), left(coalesce(p_detalle,''),1000),
          left(coalesce(p_sector,''),120), left(coalesce(p_contacto,''),120),
          case when v_verif then v_org else left(coalesce(p_organizacion,''),80) end,
          case when p_prioridad='urgente' then 'urgente' else 'normal' end,
          'abierta', nullif(p_owner,''),
          case when p_lon between -74 and -59 then p_lon else null end,
          case when p_lat between 0 and 16 then p_lat else null end,
          v_verif)
  returning * into s;
  return s;
end $$;
grant execute on function public.crear_solicitud(text,text,text,text,text,text,text,text,text,double precision,double precision,text)
  to anon, authenticated;

-- Cambiar estado: SOLO quien la creó (owner_token correcto) puede avanzarla/cerrarla.
-- p_id es text (id::text = p_id) para que PostgREST resuelva la sobrecarga sin
-- ambigüedad bigint/int (mismo patrón que mark_road_open).
create or replace function public.estado_solicitud(p_id text, p_estado text, p_owner text)
returns public.solicitudes
language plpgsql security definer set search_path = public as $$
declare s public.solicitudes;
begin
  if p_estado not in ('abierta','en_proceso','cumplida','cancelada') then raise exception 'estado invalido'; end if;
  update public.solicitudes set estado = p_estado
     where id::text = p_id and owner_token is not null and owner_token = nullif(p_owner,'')
   returning * into s;
  if s.id is null then raise exception 'no autorizado o inexistente'; end if;
  return s;
end $$;
grant execute on function public.estado_solicitud(text,text,text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 8) Denuncias públicas (voces de los afectados e injusticias)  ← NECESARIO para
--    la sección "Denuncias". Sin esta tabla, la sección se ve vacía pero no rompe.
-- ----------------------------------------------------------------------------
create table if not exists public.denuncias (
  id          bigint generated by default as identity primary key,
  categoria   text not null,    -- ayuda|refugio|servicios|agua|salud|cobros|seguridad|otros
  titulo      text not null,
  detalle     text,
  sector      text,             -- zona aproximada; NO direcciones exactas de domicilios
  respaldos   integer not null default 0,        -- apoyos de la comunidad (amplifican la voz)
  estado      text not null default 'abierta',   -- abierta|oculta
  owner_token text,             -- token anónimo del creador (no se publica)
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '30 days'
);
-- Moderación comunitaria: nº de reportes; al alcanzar el umbral, la denuncia se auto-oculta.
alter table public.denuncias add column if not exists reportes integer not null default 0;
alter table public.denuncias enable row level security;

-- Lectura pública SOLO de las vigentes y visibles. NUNCA selecciones owner_token.
drop policy if exists "lee denuncias" on public.denuncias;
create policy "lee denuncias" on public.denuncias
  for select to anon, authenticated using (estado = 'abierta' and expires_at > now());

-- Crear solo por función validada (no INSERT directo con la clave pública).
create or replace function public.crear_denuncia(
  p_categoria text, p_titulo text, p_detalle text, p_sector text, p_owner text
) returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare d public.denuncias;
begin
  if p_categoria is null or p_categoria not in
     ('ayuda','refugio','servicios','agua','salud','cobros','seguridad','otros') then
    raise exception 'categoria invalida';
  end if;
  if p_titulo is null or length(btrim(p_titulo)) < 6 then raise exception 'titulo requerido'; end if;
  insert into public.denuncias(categoria,titulo,detalle,sector,owner_token)
  values (p_categoria, left(btrim(p_titulo),140), left(coalesce(p_detalle,''),1000),
          left(coalesce(p_sector,''),120), nullif(p_owner,''))
  returning * into d;
  return d;
end $$;
grant execute on function public.crear_denuncia(text,text,text,text,text) to anon, authenticated;

-- Respaldar (apoyar) una denuncia: incrementa el contador y devuelve el nuevo total.
-- El control de "uno por dispositivo" lo hace el cliente (localStorage), igual que orar().
create or replace function public.respaldar_denuncia(p_id text)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.denuncias set respaldos = respaldos + 1
   where id::text = p_id and estado = 'abierta'
   returning respaldos into n;
  return coalesce(n, 0);
end $$;
grant execute on function public.respaldar_denuncia(text) to anon, authenticated;

-- Reportar una denuncia como inapropiada. Suma un reporte y, al alcanzar el umbral
-- (3 dispositivos distintos), la auto-oculta para todos (estado='oculta'). El control
-- de "uno por dispositivo" lo hace el cliente (localStorage). Devuelve el nuevo total.
create or replace function public.reportar_denuncia(p_id text)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.denuncias
     set reportes = reportes + 1,
         estado = case when reportes + 1 >= 3 then 'oculta' else estado end
   where id::text = p_id and estado = 'abierta'
   returning reportes into n;
  return coalesce(n, 0);
end $$;
grant execute on function public.reportar_denuncia(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 9) Alta fácil de organizaciones verificadas (panel admin en admin.html)
--    Evita tener que escribir SQL por cada aliado: desde admin.html, con tu
--    secreto, generas un código y se lo entregas a la organización.
-- ----------------------------------------------------------------------------
create table if not exists public.app_config (key text primary key, value text not null);
alter table public.app_config enable row level security;   -- sin política de SELECT => el cliente no lo lee
-- Define tu secreto de administrador (CÁMBIALO por uno largo y único):
insert into public.app_config(key, value) values ('admin_secret', 'CAMBIA-ESTE-SECRETO-largo-y-unico')
  on conflict (key) do update set value = excluded.value;

-- Generar un código para un aliado (valida el secreto admin)
create or replace function public.admin_crear_codigo(p_secret text, p_org text)
returns text language plpgsql security definer set search_path = public as $$
declare v_ok boolean; v_code text;
begin
  select (value = p_secret) into v_ok from public.app_config where key = 'admin_secret';
  if not coalesce(v_ok, false) then raise exception 'no autorizado'; end if;
  if p_org is null or length(btrim(p_org)) < 2 then raise exception 'organizacion requerida'; end if;
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.org_codes(code, organizacion) values (v_code, left(btrim(p_org), 80));
  return v_code;
end $$;
grant execute on function public.admin_crear_codigo(text, text) to anon, authenticated;

-- Listar códigos (valida el secreto admin)
create or replace function public.admin_listar_codigos(p_secret text)
returns table(code text, organizacion text, activo boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.app_config where key='admin_secret' and value=p_secret) then
    raise exception 'no autorizado'; end if;
  return query select c.code, c.organizacion, c.activo from public.org_codes c order by c.organizacion;
end $$;
grant execute on function public.admin_listar_codigos(text) to anon, authenticated;

-- Activar / desactivar un código (valida el secreto admin)
create or replace function public.admin_toggle_codigo(p_secret text, p_code text, p_activo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.app_config where key='admin_secret' and value=p_secret) then
    raise exception 'no autorizado'; end if;
  update public.org_codes set activo = p_activo where code = p_code;
end $$;
grant execute on function public.admin_toggle_codigo(text, text, boolean) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 10) Avisos PUSH con la app cerrada (suscripciones).  El envío lo hace la función
--     serverless api/push-send.js (con service_role + VAPID); aquí solo se guardan
--     las suscripciones de cada dispositivo.
-- ----------------------------------------------------------------------------
create table if not exists public.push_subs (
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  categoria  text,                      -- categoría suscrita (null = todas)
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;   -- sin política => solo el servidor (service_role) la lee

-- Guardar/actualizar la suscripción de este dispositivo (la app la llama con la clave anónima)
create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_cat text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_endpoint is null or length(p_endpoint) < 10 then raise exception 'endpoint invalido'; end if;
  insert into public.push_subs(endpoint, p256dh, auth, categoria)
  values (p_endpoint, p_p256dh, p_auth, nullif(btrim(coalesce(p_cat,'')),''))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, categoria = excluded.categoria;
end $$;
grant execute on function public.guardar_push(text, text, text, text) to anon, authenticated;

-- Borrar la suscripción (cuando el usuario desactiva o el navegador la invalida)
create or replace function public.borrar_push(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin delete from public.push_subs where endpoint = p_endpoint; end $$;
grant execute on function public.borrar_push(text) to anon, authenticated;

-- Cursor del último id de solicitud ya notificado por push (lo avanza api/push-send.js)
insert into public.app_config(key, value) values ('push_last_id', '0') on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 11) Centros de acopio EN EL EXTERIOR (diáspora) para coordinar envíos a Vzla.
--     Tabla propia (NO usa el mapa de Venezuela ni la tabla reports). Permite
--     hasta 5 fotos y un pin opcional con coordenadas mundiales. La app la llama
--     con la clave anónima vía la función crear_acopio_ext.  ← NECESARIO para la
--     sección "Acopio en el exterior". Sin esto, esa sección se ve vacía.
-- ----------------------------------------------------------------------------
create table if not exists public.acopios_ext (
  id          bigint generated by default as identity primary key,
  pais        text not null,
  ciudad      text not null,
  titulo      text not null,        -- nombre del centro u organización
  detalle     text,                 -- qué reciben, horarios, a qué zona de Vzla envían
  contacto    text,                 -- WhatsApp / teléfono / correo (público)
  fotos       text[] not null default '{}',   -- URLs del bucket público "fotos" (hasta 5)
  lon double precision, lat double precision,  -- pin opcional (coordenadas mundiales)
  owner_token text,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '60 days'
);
alter table public.acopios_ext enable row level security;
-- Lectura pública solo de las vigentes. NUNCA se selecciona owner_token desde el cliente.
drop policy if exists "lee acopios_ext" on public.acopios_ext;
create policy "lee acopios_ext" on public.acopios_ext
  for select to anon, authenticated using (expires_at > now());

-- Crear solo por función validada (no INSERT directo con la clave pública).
create or replace function public.crear_acopio_ext(
  p_pais text, p_ciudad text, p_titulo text, p_detalle text, p_contacto text,
  p_fotos text[], p_lon double precision, p_lat double precision, p_owner text
) returns public.acopios_ext
language plpgsql security definer set search_path = public as $$
declare a public.acopios_ext; v_fotos text[];
begin
  if p_pais   is null or length(btrim(p_pais))   < 2 then raise exception 'pais requerido'; end if;
  if p_ciudad is null or length(btrim(p_ciudad)) < 2 then raise exception 'ciudad requerida'; end if;
  if p_titulo is null or length(btrim(p_titulo)) < 3 then raise exception 'titulo requerido'; end if;
  v_fotos := coalesce(p_fotos, '{}');
  if array_length(v_fotos,1) > 5 then v_fotos := v_fotos[1:5]; end if;   -- tope de 5 imágenes
  insert into public.acopios_ext(pais,ciudad,titulo,detalle,contacto,fotos,lon,lat,owner_token)
  values (left(btrim(p_pais),60), left(btrim(p_ciudad),80), left(btrim(p_titulo),140),
          left(coalesce(p_detalle,''),1000), left(coalesce(p_contacto,''),160), v_fotos,
          case when p_lon between -180 and 180 then p_lon else null end,
          case when p_lat between -90  and 90  then p_lat else null end,
          nullif(p_owner,''))
  returning * into a;
  return a;
end $$;
grant execute on function public.crear_acopio_ext(text,text,text,text,text,text[],double precision,double precision,text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Notas
-- ----------------------------------------------------------------------------
-- · El cruce hospital ↔ desaparecidos (cédula/nombre) NO requiere cambios de
--   esquema: la app guarda el hash de la cédula dentro del texto del reporte.
-- · Si tu columna "id" es uuid o bigint, la función de arriba ya funciona
--   porque compara id::text = rid.
