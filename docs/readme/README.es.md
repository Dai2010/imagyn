[中文](../../README.md) · [English](README.en.md) · [Français](README.fr.md) · [Español](README.es.md) · [Русский](README.ru.md) · [العربية](README.ar.md)

# Imagyn

> **Seguridad:** los paquetes de publicación se analizaron en la **plataforma nacional de análisis colaborativo de virus informáticos** (CVERC, Centro Nacional de Respuesta a Emergencias de Virus Informáticos de China) y **pasaron las cuatro plataformas** —Android, Linux, Windows y macOS— sin código malicioso detectado. Cada versión incluye además un archivo `SHA256SUMS`: verifícalo antes de instalar. Esto solo indica que los paquetes están limpios; no es una auditoría de seguridad, y ni las llamadas a la API ni el almacenamiento de claves han sido evaluados por un tercero.

Una aplicación sencilla para crear imágenes con IA, con dos espacios: **Galería** y **Agent**. Usa tu propia clave API y conéctate directamente a un servicio compatible. Tus creaciones permanecen en tu dispositivo. Disponible para Android, Linux, Windows y macOS, con interfaz en los seis idiomas oficiales de la ONU.

> Estado: **en desarrollo.** Consulta las [funciones compatibles](#funciones-compatibles): conectar una dirección compatible no garantiza que pueda generar imágenes. Es mi primera aplicación de este tipo; gracias por la paciencia.

## Dos espacios

| Espacio | Qué hace |
| --- | --- |
| **Galería** | Genera imágenes a partir de una descripción, con ninguna o varias imágenes de referencia. Las referencias están numeradas: puedes pedir «la persona de la imagen 1 con la ropa de la imagen 2». El botón de vídeo de la barra de título abre una página aparte que produce clips de 3 a 12 segundos a partir de una frase. |
| **Agent** | Crea y modifica imágenes mediante una conversación. El diálogo y la generación tienen estados distintos; una charla normal no inicia a escondidas una generación de pago. Cada modificación se guarda como una versión independiente y las imágenes generadas también aparecen en la galería. También puede encadenar herramientas: generar imágenes, crear una presentación, añadir texto y tablas página a página, revisar las páginas en un espacio de trabajo aparte y, por último, exportar un `.pptx` editable. |

Los ajustes tienen una página propia con tres pestañas: **Imágenes / Agent / General**. Cambia de modelo durante la conversación y personaliza para cada modelo la instrucción del sistema, el número de mensajes de contexto y los parámetros de salida. Se conservan el historial y el borrador. También se puede reducir el movimiento de las animaciones.

## Características

- **Almacenamiento local:** el historial se guarda en SQLite dentro del directorio privado de la aplicación. Las creaciones son archivos locales y no dependen de direcciones temporales. Las claves API usan el almacenamiento seguro del sistema, no la base de datos.
- **Vídeo:** una página propia con siete modelos integrados — Seedance 1.0 Pro / Lite, Sora 2, Veo 3.1, Kling 2.5, Wan 2.5 y Hailuo 02 — y un ID libre o la lista obtenida del servicio de vídeo. Elige proporción, resolución, calidad, duración (3–12 segundos), marca de agua, cámara fija y semilla; el estilo se aplica desde el prompt. El servicio de vídeo puede tener su propia URL y clave en los ajustes; déjalas vacías para reutilizar el servicio de imágenes. La tarea se consulta cada 5 segundos, el clip se guarda en local y puede exportarse al dispositivo. El Agent también puede llamar a `generate_video` con los mismos parámetros, incluido el modelo.
- **Agent por pasos:** en un mismo turno puede llamar varias veces a herramientas (generación de imágenes, generación de vídeos, creación de deck, tablas, preguntas). Un fallo de herramienta se devuelve al modelo como resultado para que continúe; solo una petición fallida al modelo de texto termina el turno. Detener conserva el texto ya escrito como contexto del siguiente turno.
- **Presentaciones:** `create_deck` → `add_slide` → `add_table` → `finish_deck`, con vista previa página a página en el espacio de trabajo. La exportación es OOXML nativo `.pptx`; los cuadros de texto, las imágenes y las tablas siguen siendo editables en PowerPoint / WPS. Una tabla por diapositiva, hasta 12 filas × 8 columnas y 500 caracteres por celda.
- **Tu propio servicio:** configura las direcciones base, los modelos de imagen y conversación, el protocolo (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages) y un proxy HTTP opcional. Los modelos de conversación e imagen pueden usar servicios diferentes.
- **Estados claros:** se distinguen los errores de envío, los resultados desconocidos, la generación en curso y los errores de descarga. Si se agota el tiempo tras el envío, nunca se reenvía automáticamente una solicitud de pago; el resultado queda como «desconocido» para que lo compruebes.
- **Seis idiomas:** 中文, English, Français, Español, Русский y العربية, con diseño de derecha a izquierda para el árabe.
- **Android sin root:** guarda las imágenes generadas en la carpeta pública `Pictures/Imagyn/` mediante la API multimedia del sistema, para que sean visibles en la galería. El selector de archivos del sistema permite elegir varias referencias. No requiere Google Play Services.

## Funciones compatibles

«Compatible con OpenAI / Claude» describe un formato de solicitud. **No garantiza** generación de imágenes, límites de referencias, transparencia, resoluciones ni recuperación de tareas. Estado actual:

| API o función | Estado |
| --- | --- |
| OpenAI Images (`images/generations`, `images/edits`) | Implementado, con múltiples referencias y salida URL / Base64 |
| OpenAI Chat Completions + llamadas a herramientas | Implementado en modo Agent (`/chat/completions`) |
| OpenAI Responses + llamadas a herramientas | Implementado en modo Agent (`/responses`) |
| Anthropic Messages + llamadas a herramientas | Implementado en modo Agent |
| Generación de vídeo (envío a `videos` → consulta de `videos/{id}` → descarga desde `url` o `videos/{id}/content`) | Implementada; envío multipart por defecto y lectura tolerante de `id`/`task_id`, `status`/`task_status` y `url`/`video_url`/`data[0]` (aún sin probar contra una pasarela real) |
| Bucle de herramientas multi-paso del Agent (`generate_image`, `generate_video`, `create_deck`, `add_slide`, `add_table`, `ask_user`, …) | Implementado, hasta 32 pasos por turno; los fallos de herramientas se devuelven al modelo como resultados |
| Exportación de presentaciones (`.pptx`, cuadros de texto / imágenes / tablas) | OOXML nativo; editable en PowerPoint / WPS (apertura en un dispositivo real aún no probada) |
| WebFetch / `fetch_url` | Implementado; solo obtiene páginas http(s) públicas y rechaza direcciones locales, privadas y de enlace local |
| Resultados SSE de OpenAI Images | Implementado; se activa en las opciones de compatibilidad de la API de imágenes |
| Herramienta integrada `image_generation` de Responses | No implementada; Agent usa la función `generate_image` de la aplicación para llamar a la API Images independiente |
| Edición con máscara, tareas por lotes, sincronización en la nube, inferencia local | No implementado; posibles ampliaciones |

Una lista de modelos no demuestra que puedan generar imágenes, y comprobar la conexión no es probar la generación. Las pruebas de pago solo se inician cuando envías una solicitud explícitamente desde la galería. Más información en [docs/capabilities.md](../../docs/capabilities.md).

## Compilación

Requiere Flutter con Dart SDK ≥ 3.12.

Los directorios de cada plataforma se generan y no se guardan en Git. Después, el script añade los archivos nativos propios del repositorio:

```bash
python3 scripts/scaffold_platforms.py     # Genera android/ linux/ windows/ macos/
flutter pub get
flutter run -d <device>
flutter build apk --release
```

La CI tiene tres flujos: `check` (análisis y pruebas), `build` (APK Android de prueba) y `release` (paquetes para las cuatro plataformas, activado por etiquetas `v*`).

Paquetes publicados:

| Plataforma | Paquetes | Herramientas |
| --- | --- | --- |
| Android | APK | Firmado con el keystore de publicación |
| Linux | `.deb` / `.rpm` / `.pkg.tar.zst` | `dpkg-deb` / `rpmbuild` / `bsdtar` |
| Windows | `.exe` / `.msi` (solo x64) | Inno Setup / WiX |
| macOS | `.dmg` / `.pkg` | `hdiutil` / `pkgbuild` |

Los paquetes de escritorio **no están firmados**: Windows SmartScreen muestra «editor desconocido» y en macOS hay que abrir con el botón derecho. Evitar estos avisos requiere un certificado Authenticode y un Apple Developer ID, que todavía no tengo. **No hay versión de Windows de 32 bits**, porque Flutter no ofrece ese destino. Por ahora, lo siento por los usuarios de Windows 7 y otros sistemas win32.

## Estructura del proyecto

```text
lib/core/    Almacenamiento, modelos de datos, adaptadores API, estado de la aplicación y escritura .pptx
lib/ui/      Interfaz Galería / Agent, página de vídeo, espacio de trabajo del deck y ajustes
lib/l10n/    Textos y tablas de traducción en seis idiomas
platform/    Archivos nativos propios que se añaden a la salida de flutter create
scripts/     Generación de plataformas y traducciones
docs/        Guías de las API y de las funciones
test/        Análisis de protocolos, validación de ajustes y traducciones
```

## Documentación

Estas guías están actualmente en chino:

- [Imágenes y galería](../../docs/image-workflow.md) — API de imágenes, galería y envío de solicitudes
- [Ajustes de Agent](../../docs/agent-settings.md) — Pestañas, cambio de modelo, instrucciones y contexto personalizados
- [Capacidades](../../docs/capabilities.md) — API compatibles y gestión de errores
- [Tablas de presentación](../../docs/deck-tables.md) — Modelo, exportación y límites

## Licencia

**GPL-3.0-or-later**. Texto completo en [LICENSE](../../LICENSE). Al distribuir binarios, debes ofrecer el código fuente correspondiente. Este repositorio es público y las publicaciones también incluyen un archivo `-source.tar.gz`. Una futura distribución propietaria requeriría cambiar la licencia primero.
