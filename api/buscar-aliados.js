// Búsqueda federada EN VIVO contra el directorio aliado (desaparecidosterremotovenezuela.com).
// La app consulta este endpoint al buscar un nombre; trae coincidencias frescas de personas
// "sin-contacto" (aún no encontradas). NO copia nada a la base: siempre datos al día.
const BASE = 'https://desaparecidos-terremoto-api.theempire.tech';
const s = (v) => (v == null ? '' : String(v).trim());

module.exports = async function handler(req, res) {
  const q = s((req.query || {}).q);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=60, stale-while-revalidate=300');
  if (q.length < 2) { res.status(200).json({ ok: true, q, total: 0, items: [] }); return; }

  let size = parseInt((req.query || {}).pageSize || '10', 10);
  if (!(size > 0)) size = 10; if (size > 20) size = 20;
  const url = `${BASE}/api/personas?page=1&pageSize=${size}&estado=sin-contacto&q=${encodeURIComponent(q)}`;
  try {
    const ctrl = new AbortController(); const to = setTimeout(() => ctrl.abort(), 8000);
    const r = await fetch(url, { headers: { accept: 'application/json' }, signal: ctrl.signal });
    clearTimeout(to);
    if (!r.ok) { res.status(200).json({ ok: false, q, error: 'API ' + r.status, items: [] }); return; }
    const b = await r.json();
    const arr = Array.isArray(b.items) ? b.items : [];
    // El directorio sirve registros "honeypot"/de prueba a los scrapers: descártalos
    // para no mostrarle datos falsos a quien busca a un ser querido.
    const real = arr.filter((it) => {
      const n = s(it.nombre).toLowerCase(), d = s(it.descripcion).toLowerCase();
      return !(/registro de prueba|punto de prueba|^prueba$/.test(n) || /honeypot/.test(d));
    });
    const items = real.map((it) => ({
      nombre: s(it.nombre),
      ubicacion: s(it.ubicacion),
      edad: it.edad != null ? it.edad : null,
      descripcion: s(it.descripcion),
      estado: s(it.estado),
    }));
    res.status(200).json({ ok: true, q, total: items.length, items });
  } catch (e) {
    res.status(200).json({ ok: false, q, error: String((e && e.message) || e), items: [] });
  }
};
