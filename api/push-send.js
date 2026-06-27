// Envía avisos PUSH (con la app cerrada) de las nuevas solicitudes de ayuda.
//
// Lo dispara un programador (cron de Vercel o externo, p. ej. cron-job.org) llamando:
//   GET /api/push-send?secret=<CRON_SECRET>
//   (o con cabecera "Authorization: Bearer <CRON_SECRET>", como hace el cron de Vercel)
//
// Variables de entorno necesarias en Vercel:
//   SUPABASE_URL            (ya existe)
//   SUPABASE_SERVICE_ROLE   ← clave service_role de Supabase (SECRETA, solo en Vercel)
//   VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT (mailto:tu@correo)
//   CRON_SECRET             ← un secreto largo para proteger este endpoint
//
// Mantiene un cursor (app_config.push_last_id) para no repetir avisos.

const webpush = require('web-push');

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lzhvyjgbwynyuwylxucu.supabase.co';
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE;
const VAPID_PUBLIC = process.env.VAPID_PUBLIC;
const VAPID_PRIVATE = process.env.VAPID_PRIVATE;
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:alemandev@outlook.com';
const CRON_SECRET = process.env.CRON_SECRET;

module.exports = async function handler(req, res) {
  // Autorización: ?secret= o cabecera Authorization: Bearer
  const authHeader = String(req.headers['authorization'] || '');
  const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const secret = (req.query && req.query.secret) || bearer;
  if (!CRON_SECRET || secret !== CRON_SECRET) return res.status(401).json({ ok: false, error: 'no autorizado' });
  if (!SERVICE_KEY || !VAPID_PRIVATE || !VAPID_PUBLIC) {
    return res.status(500).json({ ok: false, error: 'faltan variables de entorno (SUPABASE_SERVICE_ROLE / VAPID_*)' });
  }

  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
  const H = { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY, 'Content-Type': 'application/json' };

  async function getConfig(k) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/app_config?select=value&key=eq.${encodeURIComponent(k)}`, { headers: H });
    const a = r.ok ? await r.json() : [];
    return (a && a[0]) ? a[0].value : null;
  }
  async function setConfig(k, v) {
    await fetch(`${SUPABASE_URL}/rest/v1/app_config?key=eq.${encodeURIComponent(k)}`, { method: 'PATCH', headers: { ...H, Prefer: 'return=minimal' }, body: JSON.stringify({ value: String(v) }) });
  }

  try {
    const lastId = parseInt((await getConfig('push_last_id')) || '0', 10) || 0;
    const rs = await fetch(`${SUPABASE_URL}/rest/v1/solicitudes?select=id,kind,titulo&tipo=eq.solicitud&estado=eq.abierta&id=gt.${lastId}&order=id.asc&limit=50`, { headers: H });
    const fresh = rs.ok ? await rs.json() : [];
    if (!Array.isArray(fresh) || !fresh.length) return res.status(200).json({ ok: true, sent: 0, reason: 'sin novedades' });

    const maxId = Math.max(...fresh.map((s) => Number(s.id)).filter((n) => isFinite(n)));
    const rsub = await fetch(`${SUPABASE_URL}/rest/v1/push_subs?select=endpoint,p256dh,auth,categoria`, { headers: H });
    const subs = rsub.ok ? await rsub.json() : [];

    let sent = 0;
    for (const sub of subs) {
      const match = fresh.filter((s) => !sub.categoria || s.kind === sub.categoria);
      if (!match.length) continue;
      const body = match.length === 1 ? String(match[0].titulo || '').slice(0, 120) : (match.length + ' nuevas solicitudes de ayuda en tu categoría');
      const payload = JSON.stringify({ title: '🆘 Nuevas solicitudes de ayuda', body, url: '/index.html', tag: 'sol-new' });
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload);
        sent++;
      } catch (err) {
        // 404/410: suscripción muerta → borrarla
        if (err && (err.statusCode === 404 || err.statusCode === 410)) {
          await fetch(`${SUPABASE_URL}/rest/v1/push_subs?endpoint=eq.${encodeURIComponent(sub.endpoint)}`, { method: 'DELETE', headers: H });
        }
      }
    }

    await setConfig('push_last_id', maxId);
    return res.status(200).json({ ok: true, sent, newSolicitudes: fresh.length, cursor: maxId });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String((e && e.message) || e) });
  }
};
