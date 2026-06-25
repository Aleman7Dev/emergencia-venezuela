# 🆘 Emergencia Sísmica · Venezuela

Aplicación web comunitaria para **coordinar reportes ciudadanos** durante una
emergencia sísmica en Venezuela: ubicar emergencias críticas, edificios y vías
dañadas, personas desaparecidas o ubicadas en hospitales, centros de acopio y
puntos de ayuda humanitaria, todo sobre un mapa interactivo.

> ⚠️ Es una herramienta de apoyo ciudadano. **No reemplaza** a las autoridades
> ni a los servicios oficiales de emergencia. Ante una urgencia, llama al **171**.

---

## ✨ Características

- **🗺️ Mapa interactivo** (Leaflet) con los reportes geolocalizados y los límites
  de estados y municipios de Venezuela.
- **📊 Estadísticas en vivo**: tarjetas resumen y una gráfica de barras con la
  distribución de reportes **por categoría** y las **zonas más afectadas**.
- **📋 Reportes por tipo**: emergencias críticas, daños en edificios, estado de
  vías, zonas sin luz/agua, desaparecidos, personas en centros de salud, acopio
  y ayuda humanitaria.
- **🧍 Búsqueda de personas** desaparecidas y localizadas en hospitales, con
  posibilidad de enlazar la **ficha oficial** en `desaparecidosterremotovenezuela.com`.
  Por seguridad **solo se aceptan enlaces de ese dominio** (HTTPS, sin trucos de
  `usuario@host`, `javascript:`, etc.), validados al guardar y al mostrar.
- **🙋 Buscadores voluntarios**: sección para que las personas se ofrezcan a
  recorrer o verificar su zona por un familiar de alguien, indicando su contacto.
- **📞 Teléfonos oficiales** de emergencia (171, Bomberos, Protección Civil,
  Cruz Roja, FUNVISIS) y líneas por operadora / ambulancias en Caracas.
- **➕ Reporte ciudadano** con ubicación por **GPS** o marcando un punto en el
  mapa, y precisión indicada (exacta / aproximada).
- **✅ Confirmación múltiple**: un reporte se retira al ser confirmado por varias
  personas distintas, reduciendo información falsa o desactualizada.
- **🔋 Modo bajo consumo**: el mapa abre sin descargar calles para ahorrar datos;
  las calles se activan a demanda.
- **📱 Diseño responsivo**: una sola columna optimizada para móvil y un layout
  amplio de dos columnas (mapa + panel de estadísticas) en escritorio.
- **🌐 Funciona aunque falle la red**: si la nube o los CDN no están disponibles,
  la app degrada con elegancia usando datos locales y de respaldo.
- **📲 Instalable (PWA)**: se puede instalar en el teléfono como una app y abre
  **sin conexión** gracias a un *service worker* que cachea la interfaz. Los
  datos de reportes siempre se piden frescos a la red (nunca se muestran datos
  obsoletos en una emergencia).

---

## 🚀 Uso

No requiere compilación: es una aplicación de un solo archivo HTML.

### Abrir localmente

Por las peticiones a archivos (`municipios-ven.json`) conviene servirla con un
servidor estático en lugar de abrir el archivo directamente:

```bash
# Con Python
python3 -m http.server 8000
# luego abre http://localhost:8000

# o con Node
npx serve .
```

### Desplegar

Sube los archivos a cualquier hosting estático (GitHub Pages, Netlify, Vercel,
Cloudflare Pages…). No hay paso de build.

---

## 🧱 Tecnología

- **HTML, CSS y JavaScript** sin framework (vanilla, un único `index.html`).
- **[Leaflet](https://leafletjs.com/)** para el mapa, con teselas de CARTO
  (activables a demanda).
- **[anime.js](https://animejs.com/)** para microanimaciones.
- **[Supabase](https://supabase.com/)** como backend de reportes (con respaldo
  local cuando no hay conexión).
- Gráfica de estadísticas dibujada con HTML/CSS puro (sin dependencias).
- **PWA**: `manifest.webmanifest` + `sw.js` (service worker) para instalación y
  uso offline. Iconos generados sin dependencias.

---

## 📁 Estructura

```
.
├── index.html             # Aplicación completa (UI + lógica)
├── municipios-ven.json    # Geometría de municipios (carga perezosa)
├── manifest.webmanifest   # Metadatos de la PWA (instalación)
├── sw.js                  # Service worker (caché / offline)
├── icon.svg               # Icono vectorial (favicon)
├── icon-192.png           # Icono PWA 192×192
├── icon-512.png           # Icono PWA 512×512
├── apple-touch-icon.png   # Icono para iOS
├── LICENSE                # Licencia MIT
└── README.md
```

---

## 🔒 Privacidad y uso responsable

Todo lo que se publica es **visible públicamente**. No incluyas información
sensible innecesaria (documentos de identidad, datos médicos detallados,
direcciones exactas de domicilios). Reporta de buena fe: **los reportes falsos
pueden costar vidas** al desviar recursos de rescate.

---

## 🤝 Contribuir

Las mejoras son bienvenidas. Al ser un único archivo, basta con editar
`index.html` y probar en el navegador. Sugerencias útiles: accesibilidad,
internacionalización, nuevas categorías de reporte y mejoras de rendimiento.

---

## 📄 Licencia

Distribuido bajo la licencia **MIT**. Consulta el archivo [`LICENSE`](./LICENSE)
para más detalles.
