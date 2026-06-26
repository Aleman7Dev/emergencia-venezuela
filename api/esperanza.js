// Contador de esperanza: personas reportadas como LOCALIZADAS A SALVO.
//
//   total = localizadas en el directorio aliado (desaparecidosterremotovenezuela.com)
//         + las que la comunidad confirmó "encontradas" en NUESTRO sitio.
//
// Se calcula del lado del servidor (Vercel) por dos razones:
//   1) El navegador no debe depender directamente de la API aliada (CORS / caché).
//   2) Unificamos una sola cifra confiable y cacheada para toda la app.
//
// Si alguna fuente falla, se devuelve lo que sí se pudo calcular (nunca rompe).

const BASE = 'https://desaparecidos-terremoto-api.theempire.tech';
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lzhvyjgbwynyuwylxucu.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx6aHZ5amdid3lueXV3eWx4dWN1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzNjc5OTksImV4cCI6MjA5Nzk0Mzk5OX0.D4B2jMLTrBgDg9VIojG1UBLDET10pfn76neJn6rm0ks';

// Localizados en el directorio aliado (counts.localizado del API público)
async function aliadoLocalizado() {
  const url = `${BASE}/api/personas?page=1&pageSize=1&estado=localizado`;
  const ctrl = new AbortController();
  const to = setTimeout(() => ctrl.abort(), 8000);
  try {
    const r = await fetch(url, { headers: { accept: 'application/json' }, signal: ctrl.signal });
    clearTimeout(to);
    if (!r.ok) return null;
    const b = await r.json();
    if (b && b.counts && b.counts.localizado != null) return Number(b.counts.localizado);
    if (b && b.total != null) return Number(b.total); // respaldo: total del filtro localizado
    return null;
  } catch (e) { clearTimeout(to); return null; }
}

// Confirmadas en nuestro sitio: reportes "miss" retirados por confirmación
// (status='atendido') o reportes marcados como "safe" (localizado a salvo).
// Usa count=exact: la cifra viene en la cabecera Content-Range (0-0/<total>).
async function propioConfirmado() {
  const filt = 'or=(and(type.eq.miss,status.eq.atendido),type.eq.safe)';
  const url = `${SUPABASE_URL}/rest/v1/reports?select=id&${filt}&limit=1`;
  try {
    const r = await fetch(url, {
      headers: {
        apikey: SUPABASE_KEY,
        Authorization: 'Bearer ' + SUPABASE_KEY,
        Prefer: 'count=exact',
      },
    });
    const cr = r.headers.get('content-range') || '';
    const m = cr.match(/\/(\d+)\s*$/);
    if (m) return parseInt(m[1], 10) || 0;
    if (r.ok) { const a = await r.json(); return Array.isArray(a) ? a.length : 0; }
    return 0;
  } catch (e) { return 0; }
}

module.exports = async function handler(req, res) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=120, stale-while-revalidate=600');
  const [aliado, propio] = await Promise.all([aliadoLocalizado(), propioConfirmado()]);
  const a = aliado != null ? aliado : 0;
  const p = propio != null ? propio : 0;
  const ok = aliado != null; // ok=false si la fuente aliada no respondió
  res.status(200).json({ ok, aliado: a, propio: p, total: a + p });
};
