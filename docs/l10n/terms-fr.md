# French (fr): terms beyond the glossary

Decisions made while translating, so later strings stay consistent. The main table is
[glossary.md](glossary.md).

## Messages

English → French, one term per line.

- bind mount → montage de liaison (topic: “Montage de liaison” / “Montages de liaison”)
- healthcheck → contrôle d’intégrité
- restart policy → stratégie de redémarrage
- driver (network / volume / logging) → pilote (“Pilote de réseau”, “Pilote de volume”, “pilote de journalisation”)
- driver options → options de réseau / options de volume
- device → périphérique
- namespace → espace de noms
- capabilities (cap_add) → capacités
- privileged mode → mode privilégié
- replicas → réplicas
- profile (Compose) → profil; “profile not active” → profil inactif
- host port → port hôte
- static IP → IP statique
- Docker engine → moteur Docker
- Docker socket → socket Docker
- registry → registre
- layer (image) → couche
- tag (image or YAML) → tag (“étiquette” is reserved for labels)
- build (an image) → générer; topic “Build” → Génération
- CPUs (count, column) → CPU (invariable: “4 CPU”, “des CPU entiers”)
- swap → swap (as in Activity Monitor)
- the `container` CLI / the docker CLI → la CLI `container` / la CLI docker
- docker shim → shim docker
- backend (“not supported by this backend”) → backend
- top-level (Compose key) → de premier niveau; “(top level)” location → (racine du fichier)
- unknown key → clé inconnue; a Compose key in messages → « la clé %@ »
- Up / Down (Compose actions named inside messages) → Up / Down, kept untranslated like Compose Up; “Down with volumes” → Down avec suppression des volumes. The app-round “Up”/“Down” buttons should match this choice.
- “Each container is its own VM” → chaque conteneur est une VM distincte
- “isn't supported” → n’est pas pris(e) en charge
- “left out” → omis
- running (in sentences) → en cours d’exécution
- Logs tab → onglet Journaux
- archive (image archive) → archive (f.)
- update information (latest.json) → informations de mise à jour
- update server → serveur de mises à jour
- checksum → somme de contrôle
- notarized → notarisée
- maintainer → mainteneur
- installer → programme d’installation
- app bundle → paquet d’app; bundle identifier → identifiant de paquet; team identifier → identifiant d’équipe
- code signature / code requirement → signature de code / exigence de code
- development build → version de développement
- Basket release (GitHub) → version publiée de Basket; “GitHub Releases” stays
- “Not enough free disk space” → Espace disque insuffisant
- YAML: mapping → mappage; list → liste; string → chaîne; integer → entier; boolean → booléen; null value → valeur nulle; node → nœud; anchor → ancre; alias → alias; merge key → clé de fusion; block scalar → scalaire de bloc; flow sequence / mapping / collection → séquence / mappage / collection de flux; escape sequence → séquence d’échappement; plain value → valeur sans guillemets
- “expected X, found Y” → « X était attendu(e), et non Y » (no agreement with Y, no elision before the placeholder)
- operation fragments for “%@ is not supported by this backend.” → masculine nouns with article (“Le démarrage d’une machine”, “L’accès aux propriétés système”, “L’enregistrement d’une image”, “Le chargement d’une image”, “Le lancement d’une commande dans un conteneur”) so « %@ n’est pas pris en charge » agrees

## Interface

- guest (VM guest) → invité; “Memory (guest)” / “Memory (host)” → Mémoire (invité) / Mémoire (hôte); “Host Memory” → Mémoire de ce Mac
- footprint → empreinte (as Activity Monitor); “VM footprint” → Empreinte de la VM
- VM overhead → surcoût de la VM
- lightweight VM → VM légère
- writable layer → couche inscriptible
- sparse (disk image) → fragmentée (as Disk Utility: “image disque fragmentée”)
- dangling (image) → orpheline; untagged → sans tag; digest → digest
- home folder → dossier de départ (column “Home” → Dossier de départ)
- Kill (SIGKILL) → Forcer l’arrêt; “Killing…” → Arrêt forcé…
- Remove Unused (prune toolbar button) → Nettoyer (the confirmation spells out what is removed)
- Unused (in the “Used By” column) → Aucun
- Exempt (Memory Saver checkbox) → Exclu; “Exempt from Memory Saver” → Exclure de l’Économiseur de mémoire
- Keep Only %@ → Conserver uniquement %@; “keeping one platform” (the operation, in sentences) and “Slimming…” → allègement / Allègement…
- states: Running / Stopped / Stopping / Unknown / Created → En cours / Arrêté / Arrêt en cours / Inconnu / Créé
- Docker states: Exited / Paused / Restarting / Removing / Dead → Terminé / En pause / Redémarrage / Suppression / Hors service
- in-progress (replaces a row’s state): Starting… / Stopping… / Restarting… / Deleting… → Démarrage… / Arrêt… / Redémarrage… / Suppression…
- detail tabs: Info / Logs / Inspect / Stats / Overview → Infos / Journaux / Inspection / Statistiques / Vue d’ensemble
- Disk I/O → E/S disque; “R %@” / “W %@” → L %@ / É %@
- Launch at login → Ouvrir Basket à l’ouverture de session; login item → élément d’ouverture
- “Update containers every” → Intervalle d’actualisation
- Dismiss (banner) → Fermer
- Show/Reveal in Finder → Afficher dans le Finder
- Release notes / What’s New → Notes de version / Nouveautés; “You’re up to date” → Basket est à jour
- Setup / Setup assistant → Configuration / Assistant de configuration; Run Setup Again… → Relancer la configuration…
- API server → serveur d’API
- Take “%@” down? (compose down) → Exécuter Down sur « %@ » ?; “Down and Delete Volumes…” → Down et supprimer les volumes…
- Recently returned (memory given back) → Mémoire rendue récemment
- status-bar counts that can’t carry a plural: invariant wording (“%lld en cours”, “%lld dans les résultats”, “inutilisées : %lld”, “Récupérable : %@”)
- banner/alert counts with two numbers: “%1$lld des %2$lld …”, “Terminées : %1$lld sur %2$lld”, “Images affichées : %1$lld sur %2$lld”
- context menu / sidebar / sheet → menu contextuel / barre latérale / fenêtre
- “for good” (data loss) → définitivement
- “a pull” (recreating needs one) → récupérer l’image
- built or loaded on this Mac → générée ou chargée sur ce Mac
