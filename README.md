# SIPPhone

SIPPhone ist ein natives macOS-SIP-Phone in Swift mit Menubar-Fokus. Die App lebt im Tray, bietet ein kompaktes Dialpad, Favoriten, letzte Anrufe, Audio-Geräteverwaltung, eingehende Anrufdialoge, Transfer, Rückfrage, Konferenz und lokale Transkription.

Technisch basiert das Projekt auf einer nativen SwiftUI-/AppKit-App mit einer C-Bridge zu PJSIP.

## Lizenzinformationen

Drittanbieter, Lizenztexte und offene Freigabeanforderungen stehen in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Die App-Bundles enthalten die
Originaltexte unter `Contents/Resources/Licenses`. Die Projektlizenz ist noch
nicht festgelegt. G.722 bleibt aktiv; G.722.1/C wird nicht gebaut oder verlinkt.

SIP-Passwoerter werden im macOS-Schluesselbund gespeichert. Vorhandene
Klartextpasswoerter in `settings.json` werden beim Laden migriert; erst nach
erfolgreicher Keychain-Speicherung wird die Datei ohne Passwort neu geschrieben.

## Build-Anleitung

Voraussetzungen:

- macOS
- Xcode Command Line Tools
- Swift
- eine gültige Code-Signing-Identity für die Installation der App

Build und Installation:

```bash
./build.sh
```

Die App wird danach standardmäßig nach folgendem Pfad installiert:

```bash
/Users/pno/Applications/SIPPhone.app
```

Starten:

```bash
open "/Users/pno/Applications/SIPPhone.app"
```

Optional können Build-Parameter überschrieben werden:

```bash
# Installationsziel ändern
INSTALL_DIR=/pfad ./build.sh

# Build-Konfiguration (debug/release, Standard: release)
BUILD_CONFIGURATION=debug ./build.sh

# Code-Signing-Identity ändern
SIGNING_IDENTITY="Developer ID Application: Name (ID)" ./build.sh
```

## Features und Vorteile

### KI-Gespraechsprotokoll

Zusaetzlich zum Originaltranskript kann automatisch ein separates KI-Protokoll
erstellt werden: Kurzfassung, Themen, Entscheidungen, Aufgaben, Fragen und
Risiken. Die Punkte enthalten Quellenzitate; unklare Zustaendigkeiten und Termine
bleiben offen. KI-Ausgaben muessen vor Verwendung geprueft werden.

Unter Einstellungen/Allgemein sind Protokoll-Anbieter und Textmodell waehlbar.
Der komplette Transkripttext wird in einem zusaetzlichen API-Aufruf uebertragen;
es entstehen weitere API-Kosten. Fuer Apple-Transkripte muss ein Cloud-Anbieter
explizit gewaehlt werden. Die zugehoerige Schluessel-Option muss aktiviert sein.
Im Gespraechsfenster kann zwischen Protokoll und Originaltranskript gewechselt
und die Protokollerzeugung unabhaengig von der Audioaufnahme wiederholt werden.

### Telefonie

- Menubar-first statt Vollfenster-App: schneller Zugriff ohne klassisches Softphone-Fenster.
- Native macOS-Integration in Swift: wirkt wie eine System-App statt wie ein portierter SIP-Client.
- Eingehende Anrufe als zentrales großes Modal auf dem Primary Screen.
- Audio-Gerätepriorisierung mit mehreren Fallback-Geräten pro Rolle statt nur einem festen Gerät.
- Offline-Erkennung für Audio-Geräte direkt in der Auswahl.
- Session-Audio-Umschaltung im laufenden Gespräch mit Pegelanzeige.
- Option, eine spontane Gerätewahl sofort dauerhaft zu priorisieren.
- Verpasste Anrufe direkt am Tray-Indikator sichtbar.
- Favoriten und letzte Anrufe direkt im kompakten Tray-Popup.
- Favoriten lassen sich sowohl manuell als auch aus letzten Anrufen übernehmen.
- T9-Übersetzung im Nummernfeld, z. B. `mmu` zu `668`.
- Rückfrage, Transfer und Konferenz direkt aus dem kompakten Call-UI.
- Lokale Mikrofon-/Bridge-Pegelanzeigen zur Audio-Diagnose.
- Lokale Transkription ohne Cloud-Zwang.
- Optional: Gemini-Integration für automatische Transkriptions-Bereinigung und Dialog-Umwandlung (mit API-Key konfigurierbar).
- Transkriptionen öffnen in einem separaten, selektierbaren Fenster.
- Sehr kompakte Bedienung für häufige Telefonie-Aufgaben mit wenig Klickwegen.
