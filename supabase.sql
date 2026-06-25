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
--   check (type in ('crit','build','road','miss','hosp','acopio','aid',
--                   'dark','water','volunteer','safe'));
--
-- b) Si "type" es un ENUM de Postgres, añade el valor:
-- alter type report_type add value if not exists 'volunteer';

-- ----------------------------------------------------------------------------
-- Notas
-- ----------------------------------------------------------------------------
-- · El cruce hospital ↔ desaparecidos (cédula/nombre) NO requiere cambios de
--   esquema: la app guarda el hash de la cédula dentro del texto del reporte.
-- · Si tu columna "id" es uuid o bigint, la función de arriba ya funciona
--   porque compara id::text = rid.
