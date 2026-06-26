// ============================================================================
//  DIAGNÓSTICO TEMPORAL — muestra de la API pública del directorio aliado.
//  Trae unos pocos registros, los normaliza a nuestro formato y los DEVUELVE
//  para revisar la calidad. NO inserta nada en la base. Protegido por ?key=.
//  Se RETIRA tras la prueba.
//
//  Uso:  /api/muestra-aliados?key=<clave>&pageSize=8[&estado=sinContacto]
// ============================================================================
const SOURCE = 'https://desaparecidos-terremoto-api.theempire.tech/api/personas';
const GATE = process.env.PROBE_KEY || 'ev-muestra-9f3a7c21';

const s = (v) => (v == null ? '' : String(v).trim());

module.exports = async function handler(req, res) {
  const q = req.query || {};
  if (s(q.key) !== GATE) { res.status(401).json({ ok: false, error: 'Falta o no coincide ?key=' }); return; }

  let pageSize = parseInt(q.pageSize || '8', 10); if (!(pageSize > 0)) pageSize = 8; if (pageSize > 25) pageSize = 25;
  const page = parseInt(q.page || '1', 10) || 1;
  const estado = s(q.estado); // '', 'sinContacto', 'localizado'
  const url = SOURCE + '?page=' + page + '&pageSize=' + pageSize + (estado ? '&estado=' + encodeURIComponent(estado) : '');

  let data;
  try {
    const ctrl = new AbortController();
    const to = setTimeout(() => ctrl.abort(), 15000);
    const r = await fetch(url, { headers: { accept: 'application/json', 'user-agent': 'emergencia-venezuela-muestra' }, signal: ctrl.signal });
    clearTimeout(to);
    if (!r.ok) { res.status(502).json({ ok: false, error: 'La API respondió ' + r.status, detalle: (await r.text()).slice(0, 300), url }); return; }
    data = await r.json();
  } catch (e) {
    res.status(502).json({ ok: false, error: 'No se pudo consultar la API', detalle: String((e && e.message) || e), url }); return;
  }

  const items = Array.isArray(data.items) ? data.items : (Array.isArray(data) ? data : []);
  const muestra = items.map((it) => ({
    type: 'miss',
    title: s(it.nombre),
    loc: s(it.ubicacion),
    need: [s(it.descripcion), s(it.contacto) ? 'Contacto: ' + s(it.contacto) : ''].filter(Boolean).join(' '),
    estado: s(it.estado),
    edad: it.edad != null ? it.edad : null,
    fechaVisto: it.fecha != null ? it.fecha : null,
    // La foto vive en el S3 de ellos; para importarla habría que re-hospedarla en nuestro bucket.
    fotoOrigen: s(it.foto) || null,
    fuente: 'desaparecidosterremotovenezuela.com',
  }));

  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(200).json({
    ok: true,
    api_total: data.total != null ? data.total : null,
    api_counts: data.counts != null ? data.counts : null,
    pagina: data.page != null ? data.page : page,
    pageSize: data.pageSize != null ? data.pageSize : pageSize,
    recibidos: muestra.length,
    ejemplo_crudo: items[0] || null,          // 1 registro tal cual viene (para ver la forma original)
    muestra_normalizada: muestra,             // cómo quedarían en nuestro formato
  });
};
