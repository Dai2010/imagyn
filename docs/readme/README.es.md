[中文](../../README.md) · [English](README.en.md) · [Français](README.fr.md) · [Español](README.es.md) · [Русский](README.ru.md) · [العربية](README.ar.md)

# Imagyn

Una aplicación sencilla para crear imágenes con IA, con dos espacios: **Galería** y **Agent**. Usa tu propia clave API y conéctate directamente a un servicio compatible. Tus creaciones permanecen en tu dispositivo. Disponible para Android, Linux, Windows y macOS, con interfaz en los seis idiomas oficiales de la ONU.

> Estado: **en desarrollo.** Consulta las [funciones compatibles](#funciones-compatibles): conectar una dirección compatible no garantiza que pueda generar imágenes. Es mi primera aplicación de este tipo; gracias por la paciencia.

## Dos espacios

| Espacio | Qué hace |
| --- | --- |
| **Galería** | Genera imágenes a partir de una descripción, con ninguna o varias imágenes de referencia. Las referencias están numeradas: puedes pedir «la persona de la imagen 1 con la ropa de la imagen 2». |
| **Agent** | Crea y modifica imágenes mediante una conversación. El diálogo y la generación tienen estados distintos; una charla normal no inicia a escondidas una generación de pago. Cada modificación se guarda como una versión independiente y las imágenes generadas también aparecen en la galería. |

Los ajustes tienen una página propia con tres pestañas: **Imágenes / Agent / General**. Cambia de modelo durante la conversación y personaliza para cada modelo la instrucción del sistema, el número de mensajes de contexto y los parámetros de salida. Se conservan el historial y el borrador. También se puede reducir el movimiento de las animaciones.

## Características

- **Almacenamiento local:** el historial se guarda en SQLite dentro del directorio privado de la aplicación. Las creaciones son archivos locales y no dependen de direcciones temporales. Las claves API usan el almacenamiento seguro del sistema, no la base de datos.
- **Tu propio servicio:** configura las direcciones base, los modelos de imagen y conversación, el protocolo (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages) y un proxy HTTP opcional. Los modelos de conversación e imagen pueden usar servicios diferentes.
- **Estados claros:** se distinguen los errores de envío, los resultados desconocidos, la generación en curso y los errores de descarga. Si se agota el tiempo tras el envío, nunca se reenvía automáticamente una solicitud de pago; el resultado queda como «desconocido» para que lo compruebes.
- **Seis idiomas:** 中文, English, Français, Español, Русский y العربية, con diseño de derecha a izquierda para el árabe.
- **Android sin root:** guarda las imágenes generadas en la carpeta pública `Pictures/Imagyn/` mediante la API multimedia del sistema, para que sean visibles en la galería. El selector de archivos del sistema permite elegir varias referencias. No requiere Google Play Services.

## Funciones compatibles

«Compatible con OpenAI / Claude» describe un formato de solicitud. **No garantiza** generación de imágenes, límites de referencias, transparencia, resoluciones ni recuperación de tareas. Estado actual:

| API o función | Estado |
| --- | --- |
| OpenAI Images (`images/generations`, `images/edits`) | Implementado, con múltiples referencias y salida URL / Base64 |
| OpenAI Chat Completions + `generate_image` | Implementado en modo Agent (`/chat/completions`) |
| OpenAI Responses + `generate_image` | Implementado en modo Agent (`/responses`) |
| Anthropic Messages + `generate_image` | Implementado en modo Agent |
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
lib/core/    Almacenamiento, modelos de datos, adaptadores API y estado de la aplicación
lib/ui/      Interfaz Galería / Agent y ajustes
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

## Licencia

**GPL-3.0-or-later**. Texto completo en [LICENSE](../../LICENSE). Al distribuir binarios, debes ofrecer el código fuente correspondiente. Este repositorio es público y las publicaciones también incluyen un archivo `-source.tar.gz`. Una futura distribución propietaria requeriría cambiar la licencia primero.
