[中文](../../README.md) · [English](README.en.md) · [Français](README.fr.md) · [Español](README.es.md) · [Русский](README.ru.md) · [العربية](README.ar.md)

# Imagyn

A minimalist AI image creation app with two entry points: **Gallery** and **Agent**. Bring your own API key and connect directly to a compatible service. Your artwork stays on your device. Available for Android, Linux, Windows and macOS, with an interface in the six official UN languages.

> Status: **work in progress.** See [Supported features](#supported-features) for the scope of support; connecting a compatible endpoint does not automatically guarantee image generation. This is my first app of this kind—thanks for your patience.

## Two entry points

| Entry point | What it does |
| --- | --- |
| **Gallery** | Generate images from a prompt, with zero or more reference images. References are numbered, so you can ask for “the person from image 1 wearing the clothes from image 2.” |
| **Agent** | Generate and refine images through conversation. Discussion and generation have separate status indicators; ordinary chat does not silently trigger paid image generation. Each edit is saved as a separate version, and generated images also appear in the gallery. |

Settings has its own page with three tabs: **Images / Agent / General**. Switch models during a conversation and customize each model’s system prompt, context message count and output parameters while keeping your history and draft. Reduced motion is also supported.

## Features

- **Local first:** History is stored in SQLite in the app’s private directory. Artwork is saved as local files rather than depending on temporary URLs. API keys use the system’s secure storage, not the database.
- **Bring your own service:** Configure base URLs, image and chat models, the protocol (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages), and an optional HTTP proxy. Chat and image models can use different services.
- **Clear task states:** Submission failures, unknown results, generation in progress and download failures are shown separately. A timeout after submission never automatically resends a paid generation request; the result stays “unknown” for you to check.
- **Six languages:** 中文, English, Français, Español, Русский and العربية, including right-to-left Arabic layout.
- **Android without root:** Save generated images to the public `Pictures/Imagyn/` folder through the system media API, where gallery apps can see them. Select multiple reference images with the system file picker. Google Play Services is not required.

## Supported features

“OpenAI / Claude compatible” describes a request format. It **does not guarantee** image generation, reference image limits, transparent backgrounds, resolutions or task recovery. The current implementation includes:

| API or feature | Status |
| --- | --- |
| OpenAI Images (`images/generations`, `images/edits`) | Implemented, including multiple reference images and URL / Base64 output |
| OpenAI Chat Completions + `generate_image` | Implemented in Agent mode (`/chat/completions`) |
| OpenAI Responses + `generate_image` | Implemented in Agent mode (`/responses`) |
| Anthropic Messages + `generate_image` | Implemented in Agent mode |
| OpenAI Images SSE results | Implemented; enable it in the image API compatibility options |
| Responses built-in `image_generation` tool | Not implemented; Agent uses the app’s `generate_image` function to call the separate Images API |
| Mask editing, batch jobs, cloud sync, local inference | Not implemented; possible future extensions |

A model list does not prove image generation capability, and a connection check is not an image generation test. Paid generation tests are only started when you explicitly submit a request in the gallery. See [docs/capabilities.md](../../docs/capabilities.md) for details.

## Build

Requires Flutter with Dart SDK ≥ 3.12.

Platform directories are generated rather than tracked in Git. The script then overlays the native files owned by this repository:

```bash
python3 scripts/scaffold_platforms.py     # Generate android/ linux/ windows/ macos/
flutter pub get
flutter run -d <device>
flutter build apk --release
```

CI has three workflows: `check` (analysis and tests), `build` (Android test APK), and `release` (four-platform packaging triggered by `v*` tags).

Release packages:

| Platform | Packages | Packaging tools |
| --- | --- | --- |
| Android | APK | Signed with the release keystore |
| Linux | `.deb` / `.rpm` / `.pkg.tar.zst` | `dpkg-deb` / `rpmbuild` / `bsdtar` |
| Windows | `.exe` / `.msi` (x64 only) | Inno Setup / WiX |
| macOS | `.dmg` / `.pkg` | `hdiutil` / `pkgbuild` |

Desktop packages **are unsigned**: Windows SmartScreen displays an “unknown publisher” warning, and macOS requires opening the app with a right-click. Avoiding these warnings requires an Authenticode certificate and an Apple Developer ID, which I don’t have yet. There is **no 32-bit Windows build** because Flutter does not provide a 32-bit Windows target. Sorry to Windows 7 and other win32 users for now.

## Project layout

```text
lib/core/    Storage, data models, API adapters and application state
lib/ui/      Gallery / Agent shell and settings
lib/l10n/    Six-language text and lookup tables
platform/    App-owned native files overlaid onto flutter create output
scripts/     Platform scaffolding and translation generation
docs/        API and feature usage guides
test/        Protocol parsing, configuration validation and translation checks
```

## Documentation

The following guides are currently in Chinese:

- [Image workflow](../../docs/image-workflow.md) — Image API behavior, gallery and submission behavior
- [Agent settings](../../docs/agent-settings.md) — Settings tabs, model switching, custom prompts and context parameters
- [Capabilities](../../docs/capabilities.md) — API support matrix and failure handling

## License

**GPL-3.0-or-later**. See [LICENSE](../../LICENSE) for the full text. Distributing binaries requires making the corresponding source available. This repository is public, and release assets also include a `-source.tar.gz` archive. Any future proprietary distribution would require a license change first.
