// Selbsttest fuer die rechnenden Teile von index.html - laeuft ohne Browser und ohne Abhaengigkeiten:
//   node selbsttest.mjs
// Geprueft wird das, was still falsch sein kann: Zeitzone der Belegung, IBAN-Pruefziffer,
// Spielerliste. Bricht mit Fehlermeldung ab, wenn eine Regel verletzt ist.
import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';
import vm from 'node:vm';

const src = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const grab = (re, was) => {
    const m = re.exec(src);
    assert.ok(m, 'nicht gefunden in index.html: ' + was);
    return m[0];
};
const teile = [
    grab(/const berlinHourFmt = [^\n]+/, 'berlinHourFmt'),
    grab(/function berlinHour\(iso\)\{[\s\S]*?\n {8}\}/, 'berlinHour'),
    grab(/function hourStart\(iso\)\{[^\n]*\}/, 'hourStart'),
    grab(/function hourEndCeil\(iso\)\{[\s\S]*?\n {8}\}/, 'hourEndCeil'),
    grab(/function ibanGueltig\(v\) \{[\s\S]*?\n {8}\}/, 'ibanGueltig'),
    grab(/function hauptbucherName\(\) \{[\s\S]*?\n {8}\}/, 'hauptbucherName'),
    grab(/function collectPlayers\(\) \{[\s\S]*?\n {8}\}/, 'collectPlayers'),
];

// DOM-Ersatz: Hauptbucher-Felder und die Namensfelder der Mitglieder
let hauptbucher = { 'p1-first': '', 'p1-last': '' };
let mitglieder = [];
const ctx = vm.createContext({
    Intl, Date,
    document: {
        getElementById: id => ({ value: hauptbucher[id] ?? '' }),
        querySelectorAll: () => mitglieder.map(v => ({ value: v })),
    },
});
vm.runInContext(teile.join('\n'), ctx);
const { hourStart, hourEndCeil, ibanGueltig, collectPlayers } = ctx;

// 1) Belegung: Backend liefert UTC -> Raster muss die Berliner Stunde sperren
assert.equal(hourStart('2026-08-25T16:00:00+00:00'), 18, 'Sommerzeit: 16:00 UTC ist 18:00 in Frittlingen');
assert.equal(hourStart('2026-01-15T16:00:00+00:00'), 17, 'Winterzeit: 16:00 UTC ist 17:00');
assert.equal(hourStart('2026-08-25T18:00:00+02:00'), 18, 'Offset +02:00 muss dasselbe ergeben');
assert.equal(hourEndCeil('2026-08-25T17:00:00+00:00'), 19, 'Ende volle Stunde');
assert.equal(hourEndCeil('2026-08-25T17:30:00+00:00'), 20, 'angefangene Stunde blockt ganz');
assert.equal(hourStart('kaputt'), null, 'Unsinn darf nicht zu Stunde 0 werden');

// Belegt-Vergleich wie in applyOccupancy: 18-19 Uhr gebucht -> 18 belegt, 17 und 19 frei
const belegt = (h, o) => hourStart(o.start) <= h && h < hourEndCeil(o.end);
const buchung = { start: '2026-08-25T16:00:00+00:00', end: '2026-08-25T17:00:00+00:00' };
assert.equal(belegt(18, buchung), true, '18 Uhr muss belegt sein');
assert.equal(belegt(17, buchung), false);
assert.equal(belegt(19, buchung), false);

// 2) IBAN-Pruefziffer
assert.equal(ibanGueltig('DE89 3704 0044 0532 0130 00'), true, 'gueltige Muster-IBAN');
assert.equal(ibanGueltig('de89370400440532013000'), true, 'klein geschrieben ist ok');
assert.equal(ibanGueltig('DE89 3704 0044 0532 0130 01'), false, 'ein Ziffernfehler muss auffallen');
assert.equal(ibanGueltig('AT61 1904 3002 3457 3201'), true, 'auch Nicht-DE');
assert.equal(ibanGueltig(''), false);
assert.equal(ibanGueltig('Sparkasse'), false);

// 3) Spielerliste: Hauptbucher darf nicht doppelt auftauchen
hauptbucher = { 'p1-first': 'Julius', 'p1-last': 'Koch' };
mitglieder = ['julius  koch', 'Anna Meier'];
let p = collectPlayers();
assert.equal(p.length, 2, 'Hauptbucher steht in der Mitgliederliste -> genau 2 Spieler');
assert.equal(p[0].name, 'Julius Koch');
assert.equal(p[0].status, 'member', 'und gilt als Mitglied');
assert.equal(p[1].name, 'Anna Meier');

mitglieder = ['Anna Meier'];
p = collectPlayers();
assert.equal(p.length, 2);
assert.equal(p[0].status, 'guest', 'nicht eingetragen -> Hauptbucher ist Gast');

mitglieder = [];
p = collectPlayers();
assert.equal(p.length, 1);
assert.equal(p[0].status, 'guest');

console.log('Selbsttest ok');
