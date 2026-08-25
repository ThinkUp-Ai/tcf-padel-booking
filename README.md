# TC Frittlingen e.V. – Website & Padel-Buchung

Vereinswebsite des Tennisclub Frittlingen e.V. mit integriertem Padel-Buchungssystem.
Läuft als GitHub Pages unter https://thinkup-ai.github.io/tcf-padel-booking/

## Inhalt

- **`index.html`** – die komplette Single-Page-Website. Eine einzige Datei mit allen
  Bereichen (Startseite, Tennis, Verein, Spielbetrieb, Mannschaften, Aktuell,
  Mitglied werden, Padel-Buchung) sowie AGB, Impressum und Datenschutzerklärung
  als Overlays. Zum Ansehen genügt ein Doppelklick – die Seite spricht auch lokal
  die echten Webhooks an.
- **`selbsttest.mjs`** – prüft die rechnenden Teile ohne Browser: `node selbsttest.mjs`
- **`sql/`** – SQL für die Buchungsdatenbank, jeweils mit Diagnose-Schritt vorweg
- Bild- und PDF-Dateien (Plätze, Mannschaften, Anfahrt, Downloads, Logos)

## Padel-Buchung

- Zwei Courts: **Cupra Court** und **Sunset Court**, im Stundentakt von 07:00 bis 23:00
- Bis 14 Tage im Voraus buchbar, Stornofrist 24 Stunden
- **26,00 €** pro Platz und Stunde, **−4,00 €** je mitspielendem Vereinsmitglied
  (also 10,00 € bei vier Mitgliedern), Schlägerverleih 2,00 € je Schläger
- Gutscheine über 1–4 Stunden, in Teilbeträgen einlösbar
- Zahlung über Mollie, Zugangscode per E-Mail für das elektronische Schließsystem
- Belegung live aus der Datenbank; ist sie nicht erreichbar, wird das Raster
  gesperrt statt fälschlich alles als frei anzuzeigen

## Technik

Statische Seite ohne Build-Schritt: HTML mit Tailwind über CDN, kein Framework,
keine Cookies, kein Tracking. Die Buchungsstrecke läuft über einen n8n-Flow
(`TCF Padel (Supabase)`) auf thinkupaiautomatisierung.de mit Supabase als
Datenbank, Mollie für Zahlungen und Tuya/Mathfel für die Zugangscodes.

## Vereinsdaten

- **Adresse:** Ecke Römerstraße / Schildeckstraße, 78665 Frittlingen
- **Kontakt:** padel@tc-frittlingen.de
- **WTB-Verein:** 20499

---

Padel-Buchung powered by **ThinkUp-AI**
