[中文](../../README.md) · [English](README.en.md) · [Français](README.fr.md) · [Español](README.es.md) · [Русский](README.ru.md) · [العربية](README.ar.md)

# Imagyn

Une application sobre de création d’images par IA, avec deux espaces : **Galerie** et **Agent**. Utilisez votre propre clé API et connectez-vous directement à un service compatible. Vos créations restent sur votre appareil. Disponible sur Android, Linux, Windows et macOS, avec une interface dans les six langues officielles de l’ONU.

> État : **en développement.** Consultez les [fonctionnalités prises en charge](#fonctionnalités-prises-en-charge) : une adresse compatible ne garantit pas la génération d’images. C’est ma première application de ce type ; merci de votre patience.

## Deux espaces

| Espace | Fonction |
| --- | --- |
| **Galerie** | Générez des images à partir d’une description, avec ou sans images de référence. Les références sont numérotées : vous pouvez demander « le personnage de l’image 1 avec les vêtements de l’image 2 ». |
| **Agent** | Créez et modifiez des images par conversation. Discussion et génération ont des états distincts ; une conversation ordinaire ne déclenche pas discrètement une génération payante. Chaque modification est enregistrée séparément, et les images créées apparaissent aussi dans la galerie. |

Les paramètres disposent d’une page dédiée avec trois onglets : **Images / Agent / Général**. Changez de modèle pendant une conversation et personnalisez, pour chaque modèle, l’instruction système, le nombre de messages de contexte et les paramètres de sortie. L’historique et le brouillon sont conservés. Une option réduit les animations.

## Fonctionnalités

- **Priorité au stockage local :** l’historique est enregistré dans SQLite, dans le dossier privé de l’application. Les créations sont des fichiers locaux, sans dépendance à des adresses temporaires. Les clés API utilisent le stockage sécurisé du système, pas la base de données.
- **Votre propre service :** configurez les adresses de base, les modèles d’image et de conversation, le protocole (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages) et, éventuellement, un proxy HTTP. Les modèles de conversation et d’image peuvent utiliser des services différents.
- **États explicites :** échec d’envoi, résultat inconnu, génération en cours et échec de téléchargement sont distingués. Après un délai d’attente dépassé, une requête payante n’est jamais renvoyée automatiquement ; le résultat reste « inconnu » pour vous laisser vérifier.
- **Six langues :** 中文, English, Français, Español, Русский et العربية, avec une mise en page de droite à gauche pour l’arabe.
- **Android sans root :** les images sont enregistrées dans le dossier public `Pictures/Imagyn/` via l’API multimédia du système et sont visibles dans les applications de galerie. Les références se sélectionnent dans le sélecteur de fichiers système, qui accepte plusieurs fichiers. Google Play Services n’est pas nécessaire.

## Fonctionnalités prises en charge

« Compatible OpenAI / Claude » désigne un format de requête et **ne garantit pas** la génération d’images, le nombre de références, la transparence, les résolutions ou la récupération des tâches. État actuel :

| API ou fonctionnalité | État |
| --- | --- |
| OpenAI Images (`images/generations`, `images/edits`) | Implémenté, avec plusieurs références et des sorties URL / Base64 |
| OpenAI Chat Completions + `generate_image` | Implémenté en mode Agent (`/chat/completions`) |
| OpenAI Responses + `generate_image` | Implémenté en mode Agent (`/responses`) |
| Anthropic Messages + `generate_image` | Implémenté en mode Agent |
| Résultats OpenAI Images en SSE | Implémenté ; activation dans les options de compatibilité de l’API d’images |
| Outil intégré `image_generation` de Responses | Non implémenté ; Agent utilise la fonction `generate_image` de l’application pour appeler l’API Images séparée |
| Modification par masque, tâches par lots, synchronisation cloud, inférence locale | Non implémenté ; extensions possibles |

Une liste de modèles ne prouve pas leur capacité à générer des images, et un contrôle de connexion n’est pas un test de génération. Les tests payants ne démarrent que lorsque vous soumettez explicitement une demande dans la galerie. Voir [docs/capabilities.md](../../docs/capabilities.md).

## Compilation

Nécessite Flutter avec Dart SDK ≥ 3.12.

Les dossiers de plateforme sont générés et ne sont pas suivis dans Git. Le script y superpose ensuite les fichiers natifs propres à ce dépôt :

```bash
python3 scripts/scaffold_platforms.py     # Génère android/ linux/ windows/ macos/
flutter pub get
flutter run -d <device>
flutter build apk --release
```

La CI comprend trois workflows : `check` (analyse et tests), `build` (APK Android de test) et `release` (paquets pour les quatre plateformes, déclenchés par les tags `v*`).

Paquets distribués :

| Plateforme | Paquets | Outils |
| --- | --- | --- |
| Android | APK | Signé avec le keystore de publication |
| Linux | `.deb` / `.rpm` / `.pkg.tar.zst` | `dpkg-deb` / `rpmbuild` / `bsdtar` |
| Windows | `.exe` / `.msi` (x64 uniquement) | Inno Setup / WiX |
| macOS | `.dmg` / `.pkg` | `hdiutil` / `pkgbuild` |

Les paquets pour ordinateur **ne sont pas signés** : Windows SmartScreen indique un « éditeur inconnu » et macOS demande une ouverture par clic droit. Éviter ces avertissements nécessite un certificat Authenticode et un Apple Developer ID, que je n’ai pas encore. Il n’existe **pas de version Windows 32 bits**, car Flutter ne propose pas cette cible. Désolé, pour le moment, pour les utilisateurs de Windows 7 et des autres systèmes win32.

## Structure du projet

```text
lib/core/    Stockage, modèles de données, adaptateurs API et état de l’application
lib/ui/      Interface Galerie / Agent et paramètres
lib/l10n/    Textes et tables de traduction en six langues
platform/    Fichiers natifs propres au projet ajoutés à la sortie de flutter create
scripts/     Génération des plateformes et des traductions
docs/        Guides des API et des fonctionnalités
test/        Analyse des protocoles, validation des paramètres et des traductions
```

## Documentation

Les guides suivants sont actuellement en chinois :

- [Images et galerie](../../docs/image-workflow.md) — API d’images, galerie et envoi des demandes
- [Paramètres Agent](../../docs/agent-settings.md) — Onglets, changement de modèle, instructions et contexte personnalisés
- [Capacités](../../docs/capabilities.md) — API prises en charge et gestion des échecs

## Licence

**GPL-3.0-or-later**. Texte intégral dans [LICENSE](../../LICENSE). La distribution de binaires impose de fournir le code source correspondant. Ce dépôt est public et les publications incluent aussi une archive `-source.tar.gz`. Une éventuelle distribution propriétaire nécessiterait d’abord un changement de licence.
