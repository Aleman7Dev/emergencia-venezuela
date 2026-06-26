// Vista previa enriquecida por persona/reporte para enlaces ?p=<id>.
//
// Los rastreadores de redes sociales (WhatsApp, Facebook, Twitter, Telegram) no
// ejecutan JavaScript: solo leen las etiquetas Open Graph del HTML inicial. Por
// eso esta función serverless intercepta "/?p=<id>", busca ese reporte en
// Supabase e inyecta un og:title / og:description propios de esa persona antes
// de devolver la misma app. Las personas reales reciben la app completa, que al
// cargar lee ?p= y enfoca la tarjeta (ver focusReport en index.html).
//
// Nunca se publican datos sensibles: la cédula se guarda solo como hash (CIH:),
// y los tokens internos (enlace de ficha, CIH:, estado de vía RS:) se eliminan
// del texto de la vista previa.

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lzhvyjgbwynyuwylxucu.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx6aHZ5amdid3lueXV3eWx4dWN1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzNjc5OTksImV4cCI6MjA5Nzk0Mzk5OX0.D4B2jMLTrBgDg9VIojG1UBLDET10pfn76neJn6rm0ks';

const TYPE_LABEL = {
  crit: 'Emergencia crítica', build: 'Edificio dañado', escombros: 'Remoción de escombros',
  road: 'Estado de vialidad', miss: 'Persona desaparecida', hosp: 'Persona en centro de salud',
  acopio: 'Centro de acopio', aid: 'Punto de ayuda humanitaria',
  dark: 'Zona sin luz', water: 'Zona sin agua', volunteer: 'Buscador voluntario',
  safe: 'Persona a salvo'
};
const TYPE_EMOJI = {
  crit: '🚨', build: '🏚️', escombros: '🧱', road: '🛣️', miss: '🧍', hosp: '🏥', acopio: '📦',
  aid: '⛑️', dark: '🌑', water: '💧', volunteer: '🙋', safe: '✅'
};
const DEFAULT_DESC = {
  miss: 'Ayúdanos a ubicar a esta persona tras el terremoto en Venezuela.',
  hosp: 'Persona reportada en un centro de salud tras el terremoto en Venezuela.',
  volunteer: 'Buscador voluntario disponible para recorrer o verificar una zona.'
};

// Quita tokens internos y enlaces del texto antes de mostrarlo públicamente
function stripTokens(s) {
  return String(s == null ? '' : s)
    .replace(/\bIMG:https?:\/\/\S+/gi, '')
    .replace(/https?:\/\/\S+/gi, '')
    .replace(/\bCIH:[0-9a-f]+\b/gi, '')
    .replace(/\bRS:(closed|partial|moto|foot|open)\b/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}
// Escapado para el valor de un atributo HTML (content="...")
function escAttr(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
// Escapado para texto entre etiquetas (<title>...</title>)
function escText(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function clip(s, n) {
  s = String(s || '').trim();
  return s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s;
}
// Reemplaza (o inserta) una etiqueta <meta>, robusto al orden de atributos
function setMeta(html, attrName, key, value) {
  const safeKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp('<meta\\s+' + attrName + '=["\']' + safeKey + '["\'][^>]*>', 'i');
  const tag = '<meta ' + attrName + '="' + key + '" content="' + escAttr(value) + '">';
  return re.test(html) ? html.replace(re, tag) : html.replace(/<\/head>/i, tag + '\n</head>');
}

module.exports = async function handler(req, res) {
  const proto = (req.headers['x-forwarded-proto'] || 'https').split(',')[0];
  const host = req.headers['x-forwarded-host'] || req.headers.host || 'emergenciavenezuela.digital';
  const base = proto + '://' + host;

  // id del reporte (?p=)
  let pid = (req.query && req.query.p) || '';
  if (Array.isArray(pid)) pid = pid[0];
  pid = String(pid || '').trim();

  // Trae la app estática para devolver siempre algo usable
  async function baseHtml() {
    const r = await fetch(base + '/index.html', { headers: { 'user-agent': 'og-render' } });
    if (!r.ok) throw new Error('base ' + r.status);
    return await r.text();
  }

  // Sin id válido: servir la app tal cual (vista previa genérica)
  if (!pid || pid.length > 80) {
    try {
      const html = await baseHtml();
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Cache-Control', 'public, s-maxage=300, stale-while-revalidate=600');
      return res.status(200).send(html);
    } catch (e) {
      res.writeHead(302, { Location: '/index.html' });
      return res.end();
    }
  }

  let rp = null;
  try {
    const url = SUPABASE_URL + '/rest/v1/reports?id=eq.' + encodeURIComponent(pid) +
      '&select=type,title,loc,need&limit=1';
    const r = await fetch(url, { headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + SUPABASE_KEY } });
    if (r.ok) { const rows = await r.json(); if (Array.isArray(rows) && rows.length) rp = rows[0]; }
  } catch (e) { /* sin reporte: seguimos con la vista genérica */ }

  let html;
  try { html = await baseHtml(); }
  catch (e) {
    // Respaldo: HTML mínimo con OG + redirección a la app (a /index.html para no
    // re-entrar en esta función) por si la app estática no estuviera disponible
    const label = (rp && TYPE_LABEL[rp.type]) || 'Reporte ciudadano';
    const t = escText(label + ' · Emergencia Sísmica Venezuela');
    const target = '/index.html?p=' + encodeURIComponent(pid);
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.status(200).send(
      '<!doctype html><html lang="es"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>' + t + '</title>' +
      '<meta property="og:title" content="' + escAttr(label) + '">' +
      '<meta property="og:site_name" content="Emergencia Sísmica Venezuela">' +
      '<meta property="og:image" content="' + base + '/icon-512.png">' +
      '<meta http-equiv="refresh" content="0; url=' + target + '">' +
      '</head><body style="font-family:system-ui;background:#0d1117;color:#e6edf3;padding:24px">' +
      'Abriendo Emergencia Sísmica Venezuela… <a style="color:#3b82f6" href="' + target + '">Abrir</a>' +
      '<script>location.replace(' + JSON.stringify(target) + ')</script></body></html>'
    );
  }

  // Sin reporte encontrado: app con vista previa genérica (sin tocar OG)
  if (rp) {
    const type = rp.type || '';
    const label = TYPE_LABEL[type] || 'Reporte ciudadano';
    const emoji = TYPE_EMOJI[type] || '📍';
    const titleClean = stripTokens(rp.title) || label;
    const locClean = stripTokens(rp.loc);
    const needClean = stripTokens(rp.need);
    // Foto (si existe y es de nuestro bucket público): se usará como imagen de la vista previa
    let photo = null;
    const pm = String(rp.need || '').match(/\bIMG:(https:\/\/[^\s"'<>]+)/i);
    if (pm) { try { const u = new URL(pm[1]); if (u.protocol === 'https:' && u.hostname === new URL(SUPABASE_URL).hostname && u.pathname.startsWith('/storage/v1/object/public/')) photo = u.href; } catch (e) {} }

    const ogTitle = emoji + ' ' + clip(titleClean, 70) + ' — ' + label;
    let desc = '';
    if (locClean) desc += '📍 ' + locClean + '. ';
    desc += needClean ? clip(needClean, 150)
      : (DEFAULT_DESC[type] || 'Reporte ciudadano del terremoto en Venezuela sobre el mapa.');
    desc = clip(desc, 200);

    const ogUrl = base + '/?p=' + encodeURIComponent(pid);
    const pageTitle = clip(ogTitle + ' · Emergencia Venezuela', 120);

    html = html.replace(/<title>[\s\S]*?<\/title>/i, '<title>' + escText(pageTitle) + '</title>');
    html = setMeta(html, 'name', 'description', desc);
    html = setMeta(html, 'property', 'og:title', ogTitle);
    html = setMeta(html, 'property', 'og:description', desc);
    html = setMeta(html, 'property', 'og:url', ogUrl);
    html = setMeta(html, 'name', 'twitter:title', ogTitle);
    html = setMeta(html, 'name', 'twitter:description', desc);
    if (photo) {
      html = setMeta(html, 'property', 'og:image', photo);
      html = setMeta(html, 'name', 'twitter:image', photo);
      html = setMeta(html, 'name', 'twitter:card', 'summary_large_image');
    }
  }

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=120, stale-while-revalidate=600');
  return res.status(200).send(html);
};
