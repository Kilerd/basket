# German (de): terms beyond the glossary

Decisions made while translating, so later strings stay consistent. The main table is
[glossary.md](glossary.md).

## Messages

English → German, one per line.

Up / Down (Compose actions named in messages) → „Up“ / „Down“ (untranslated like Compose Up, quoted in running text)
mount (verb) → einbinden ("ist eingebunden"); noun stays Mount
bind mount → Bind-Mount
named volume / anonymous volume → benanntes Volume / anonymes Volume
layer (image) → Layer (der, pl. Layer)
memory limit → Arbeitsspeicherlimit
default (memory, network) → Standard (Standardnetzwerk; "Arbeitsspeicher: Standard")
publish (a port) → veröffentlichen
exposed port → exponierter Port (never "freigegeben", which means reclaim)
host port → Host-Port
host networking → Host-Netzwerk
capabilities (Linux) → Capabilities
restart policy → Neustartrichtlinie
healthcheck → Healthcheck
profile (Compose) → Profil
replicas → Replikate
reservations → Reservierungen
driver (network/volume) → Treiber (Netzwerktreiber, Volume-Treiber)
secrets / configs (Compose) → Secrets / Configs (untranslated)
namespaces / sysctls → Namespaces / Sysctls (untranslated)
top level (of a Compose file) → oberste Ebene ("(oberste Ebene)", "auf oberster Ebene")
key (YAML/Compose) → Schlüssel
mapping (YAML) → Mapping (das)
list / list item (YAML) → Liste / Listeneintrag
flow sequence / flow mapping → Flow-Sequenz / Flow-Mapping
block scalar / scalar → Blockskalar / Skalar
anchor / alias / tag / node (YAML) → Anker / Alias / Tag / Knoten
merge key → Merge-Schlüssel
escape sequence → Escape-Sequenz
indentation / indent → Einrückung / einrücken
string / boolean / integer / null value → String / boolescher Wert / Ganzzahl / Nullwert
YAML value kinds ("a list", "a string" …) → accusative with article: eine Liste, einen String, ein Mapping, einen booleschen Wert …
"expected X, found Y" → "X erwartet, aber Y gefunden"
unterminated → nicht abgeschlossen
isn't supported → wird nicht unterstützt
ignored → wird ignoriert
left out → wird weggelassen
skipped → übersprungen
variant %@ → Variante %@ (placeholder after the noun, no "%@-Variante" compound)
archive (image archive) → Archiv; image archive → Image-Archiv
save / load (image archive) → speichern / laden
export → exportieren
update information (release manifest) → Update-Informationen
update server → Update-Server
bundle identifier / team identifier → Bundle-ID / Team-ID
code signed / signed ad hoc / notarized → codesigniert / ad hoc signiert / notarisiert
development build → Entwicklungs-Build
maintainer → Maintainer
installer (update helper) → Installationsprogramm
checksum → Prüfsumme
signing requirement / code requirement → Signaturanforderung / Code-Anforderung
Applications folder → Ordner „Programme“ (the name Finder shows)
docker shim → docker-Shim
registry → Registry
timed out → Zeitüberschreitung
exit status → Exit-Status
operation names inside "%@ is not supported by this backend." → nominalised with article: „Das Starten einer Maschine“, „Das Laden eines Images“
progress lines → passive "X wird erstellt/gestartet/gelöscht"; with a list placeholder: „Stoppen von %@“, „Löschen von %@“
"%lld of %lld containers" banners → "%1$lld von %2$lld Containern …" (avoids verb agreement with the first number)
em dash in English running text → spaced en dash " – " (German convention)

## Interface

Memory (narrow table column / stats tile) → RAM; Host Memory → Host-RAM; Memory (guest) / (host) → RAM (Gast) / RAM (Host). Width exception only: sentences, settings, alerts and chart titles keep Arbeitsspeicher (glossary)
On Disk (column) / "%@ on disk" → Belegt / "%@ belegt"
Used By (column) → Genutzt von; "Used by %@." → "Wird von %@ verwendet."
Disk (card, footer, machine column) → Festplatte; Disk I/O → Festplatten-E/A; R %@ / W %@ → L %@ / S %@ (Lesen / Schreiben)
disk image (sparse volume file, OrbStack data image) → Festplattenimage (never bare "Image", which means a container image)
sparse → mitwachsend (as Disk Utility's "mitwachsendes Image")
home folder → Benutzerordner (also the machine column "Home")
load from an archive vs pull → "aus einem Archiv geladen" vs "laden"; "pulled images" → "aus einer Registry geladene Images"
slim / keep one platform → verschlanken: "Keep Only %@" → "Nur %@ behalten"; "Keeping only…" → "… wird auf %@ verschlankt"; "Kept only %@" → "Auf %@ verschlankt"
Kill (SIGKILL) → Sofort beenden (Apple's Force Quit wording); Killing… → Wird beendet …
Stop Idle Containers / idle container → Container im Leerlauf stoppen
Exempt / Exempt from Memory Saver → Ausgenommen / Vom Speichersparmodus ausnehmen
Make Default (toolbar) → Als Standard; Make this the default machine → Diese Maschine als Standard festlegen
state cells (in progress) → compact: Startet … / Stoppt … / Startet neu … / Wird gelöscht … / Wird entfernt … / Wird festgelegt … (setting as default)
container states → Läuft, Gestoppt, Erstellt, Beendet (exited), Angehalten (paused), Startet neu, Wird entfernt, Stoppt, Defekt (dead), Unbekannt
running (status-bar counts) → aktiv ("%lld aktiv", "%1$lld von %2$lld aktiv")
Dangling (image) → verwaist
writable layer → beschreibbarer Layer
VM overhead / VM footprint → VM-Overhead / Bedarf der VM
Top consumers → Größte Verbraucher
Follow (logs toggle) / following → Verfolgen / live
Inspect (detail tab, raw JSON) → Inspect (command name)
Release notes → Versionshinweise; What's New → Neuerungen
login item → Anmeldeobjekt; Launch at login → Beim Anmelden öffnen
Setup → Einrichtung; Setup assistant → Einrichtungsassistent; Summary (setup step) → Zusammenfassung; Ready (last step) → Bereit
docker command → docker-Befehl; container CLI → container-CLI
Take “%@” down? / Couldn't take the project down → „%@“ herunterfahren? / Projekt konnte nicht heruntergefahren werden (Down / Up buttons stay "Down" / "Up")
Update containers every [1/2/5/10 seconds] → Container aktualisieren [Jede Sekunde / Alle 2 Sekunden …]
Stop containers idle for [duration] → Container stoppen nach Leerlauf von [duration]
Reveal (button) / Show in Finder → Anzeigen / Im Finder anzeigen
Dismiss → Schließen
lightweight VM → leichte VM
