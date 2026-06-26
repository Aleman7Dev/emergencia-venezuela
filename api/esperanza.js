// Contador de esperanza: personas reportadas como LOCALIZADAS A SALVO.
//
//   total = localizadas según el directorio nacional (desaparecidosterremotovenezuela.com)
//         + personas confirmadas como encontradas en NUESTRO sitio.
//
// Nota (jun 2026): el espejo no oficial del directorio (theempire.tech) quedó
// bloqueado contra scraping y ahora devuelve un "honeypot" (un registro de
// prueba) en lugar de datos reales. Por eso:
//   · Si la API en vivo responde una cifra razonable (> 1000), se usa.
//   · Si devuelve 0 / honeypot / falla, se usa ALIADO_LOCALIZADOS (cifra del
//     directorio, configurable como variable de entorno en Vercel; por defecto
//     una instantánea reciente). La cifra siempre se atribuye al directorio.
// Lo "nuestro" se cuenta en vivo desde Supabase y nunca depende del directorio.

const BASE = 'https://desaparecidos-terremoto-api.theempire.tech';
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lzhvyjgbwynyuwylxucu.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx6aHZ5amdid3lueXV3eWx4dWN1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzNjc5OTksImV4cCI6MjA5Nzk0Mzk5OX0.D4B2jMLTrBgDg9VIojG1UBLDET10pfn76neJn6rm0ks';

// Cifra del directorio nacional (configurable). Si el scraping en vivo no da una
// cifra fiable, se usa esta instantánea (actualizable sin tocar código).
// Última cifra oficial de desaparecidosterremotovenezuela.com: 8.161 localizados (jun 2026).
const ALIADO_BASE = parseInt(process.env.ALIADO_LOCALIZADOS || '8161', 10) || 0;
// Por debajo de esto consideramos que la respuesta es honeypot/ruido y la ignoramos.
const ALIADO_MIN_FIABLE = 1000;

// Intenta leer counts.localizado del directorio aliado en vivo.
async function aliadoLocalizadoLive() {
  const url = `${BASE}/api/personas?page=1&pageSize=1&estado=localizado`;
  const ctrl = new AbortController();
  const to = setTimeout(() => ctrl.abort(), 7000);
  try {
    const r = await fetch(url, { headers: { accept: 'application/json' }, signal: ctrl.signal });
    clearTimeout(to);
    if (!r.ok) return null;
    const b = await r.json();
    if (b && b.counts && b.counts.localizado != null) return Number(b.counts.localizado);
    if (b && b.total != null) return Number(b.total);
    return null;
  } catch (e) { clearTimeout(to); return null; }
}

// Confirmadas en nuestro sitio: reportes 'miss' retirados por confirmación
// (status='atendido') o reportes 'safe'. count=exact -> cabecera Content-Range.
async function propioConfirmado() {
  const filt = 'or=(and(type.eq.miss,status.eq.atendido),type.eq.safe)';
  const url = `${SUPABASE_URL}/rest/v1/reports?select=id&${filt}&limit=1`;
  try {
    const r = await fetch(url, {
      headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY, Prefer: 'count=exact' },
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
  res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=900');
  const [live, propio] = await Promise.all([aliadoLocalizadoLive(), propioConfirmado()]);
  const aliadoLive = live != null && live > ALIADO_MIN_FIABLE; // descarta honeypot/0
  const aliado = aliadoLive ? live : ALIADO_BASE;
  const p = propio != null ? propio : 0;
  res.status(200).json({ ok: aliado + p > 0, aliado, propio: p, total: aliado + p, aliadoLive });
};
