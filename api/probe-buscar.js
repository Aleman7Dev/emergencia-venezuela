// DIAGNÓSTICO TEMPORAL — descubre cómo busca por nombre la API aliada.
// Prueba varios parámetros/rutas a la vez y reporta cuál FILTRA los resultados.
// Se retira tras la prueba. Uso: /api/probe-buscar?key=<clave>&q=maria
const BASE = 'https://desaparecidos-terremoto-api.theempire.tech';
const GATE = process.env.PROBE_KEY || 'ev-muestra-9f3a7c21';
const s = (v) => (v == null ? '' : String(v).trim());

module.exports = async function handler(req, res) {
  const q = req.query || {};
  if (s(q.key) !== GATE) { res.status(401).json({ ok: false, error: 'Falta o no coincide ?key=' }); return; }
  const term = s(q.q) || 'maria';
  const e = encodeURIComponent(term);
  const candidates = [
    { param: 'q', url: `/api/personas?page=1&pageSize=5&q=${e}` },
    { param: 'search', url: `/api/personas?page=1&pageSize=5&search=${e}` },
    { param: 'nombre', url: `/api/personas?page=1&pageSize=5&nombre=${e}` },
    { param: 'query', url: `/api/personas?page=1&pageSize=5&query=${e}` },
    { param: 'buscar', url: `/api/personas?page=1&pageSize=5&buscar=${e}` },
    { param: 'texto', url: `/api/personas?page=1&pageSize=5&texto=${e}` },
    { param: 'filtro', url: `/api/personas?page=1&pageSize=5&filtro=${e}` },
    { param: 'ruta /buscar', url: `/api/personas/buscar?q=${e}&pageSize=5` },
    { param: 'ruta /search', url: `/api/search?q=${e}&pageSize=5` },
  ];
  async function probe(c) {
    try {
      const ctrl = new AbortController(); const to = setTimeout(() => ctrl.abort(), 9000);
      const r = await fetch(BASE + c.url, { headers: { accept: 'application/json' }, signal: ctrl.signal });
      clearTimeout(to);
      let total = null, nombres = [];
      if (r.ok) { try { const b = await r.json(); const items = Array.isArray(b.items) ? b.items : (Array.isArray(b) ? b : []); total = b && b.total != null ? b.total : null; nombres = items.slice(0, 5).map((x) => s(x.nombre)); } catch (_) {} }
      return { param: c.param, status: r.status, total, nombres };
    } catch (err) { return { param: c.param, status: 'ERR', detalle: String((err && err.message) || err) }; }
  }
  const resultados = await Promise.all(candidates.map(probe));
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(200).json({
    ok: true, term, baseline_total: 58599,
    pista: 'El parámetro que FILTRA es aquel cuyo "total" baja mucho y cuyos "nombres" contienen el término. Si todos muestran ~58599, ese parámetro no busca.',
    resultados,
  });
};
