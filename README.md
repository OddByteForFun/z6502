# Émulateur Oric 1 / Oric Atmos en Zig 0.16 (MOS 6502)

Un émulateur complet, performant et autonome des micro-ordinateurs 8-bits **Oric Atmos** et **Oric 1** (Tangerine Computer Systems, 1983-1984), écrit en langage **Zig 0.16**.

Conçu à l'instar du projet de référence en Rust (`mos6502`), ce projet implémente avec précision l'ensemble des composants matériels de la machine en tirant parti des atouts de Zig : absence d'allocations cachées, métaprogrammation comptime, interopérabilité C native sans surcoût et contrôle bas niveau strict.

---

## 🌟 Fonctionnalités

- **Microprocesseur MOS 6502 cycle-accurate** :
  - Jeu d'instructions complet (151 opcodes officiels) et modes d'adressage exacts.
  - Arithmétique décimale rigoureuse (mode BCD pour `ADC` / `SBC`) conforme au silicium NMOS 6502, indispensable pour le bon fonctionnement du BASIC Microsoft / Tangerine.
  - Gestion des interruptions matérielles (`IRQ`, `NMI`, `RESET`) et bugs historiques (ex: bug de franchissement de page sur saut indirect `JMP ($xxFF)`).
- **Architecture mémoire complète (64 Ko)** :
  - 48 Ko de RAM système ($0000..$BFFF).
  - Décodage miroir de la page d'E/S ($0300..$03FF).
  - 16 Ko de ROM système intégrée (Oric Atmos BASIC v1.1 et Oric 1 BASIC v1.0 intégrées à la compilation via `@embedFile`).
  - Prise en charge de ROMs personnalisées (ex: Sedoric, ROM de diagnostic, etc.) via l'argument `-r / --rom`.
- **Circuit d'interface MOS 6522 VIA** :
  - Timer 1 en mode rechargement continu cadencé à 1 MHz pour générer l'interruption système à 100 Hz.
  - Timer 2 pour la gestion des temporisations.
  - Ports d'E/S A et B connectés respectivement au processeur sonore et à la matrice clavier.
  - Lignes de contrôle CA2 / CB2 pilotant les signaux BC1 / BDIR du chip sonore.
- **Processeur Sonore General Instrument AY-3-8912** :
  - 3 canaux sonores carrés indépendants.
  - Générateur de bruit pseudo-aléatoire (LFSR 17 bits).
  - Générateur d'enveloppe matérielle (formes d'onde avec attack, decay, hold, alternate).
  - Table DAC logarithmique authentique à 16 niveaux.
  - Port d'E/S parallèle 8 bits (Registre 14) relié aux colonnes du clavier.
  - Échantillonnage audio à 44 100 Hz transmis en flux continu à la file audio SDL2.
- **Contrôleur Vidéo Ferranti ULA (HCS10017)** :
  - Résolution d'écran 240 × 224 pixels (PAL 50 Hz).
  - Mode texte LORES (40 colonnes × 28 lignes, 1120 octets à $BB80..$BFDF).
  - Mode graphique HIRES (40 × 200 octets à $A000..$BF3F + 3 lignes de texte au bas de l'écran à $BF68..$BFDF).
  - Attributs séries ULA complets :
    - Couleurs d'encre (Ink 0..7) et de fond (Paper 0..7).
    - Double hauteur de caractères (alternance des demi-glyphes paires/impaires).
    - Clignotement du texte (Blink à ~3 Hz).
    - Jeu de caractères alternatif et vidéo inverse.
    - Réinitialisation matérielle en début de chaque ligne de balayage (`SelReload` : Encre blanche / Fond noir).
  - Police officielle standard Oric 6x8 intégrée.
- **Clavier matriciel (8 × 8)** :
  - Prise en charge native des claviers hôtes **AZERTY** (par défaut) et **QWERTY**.
  - Gestion avancée des modificateurs hôtes : synthèse automatique de la touche Maj (Shift) pour les symboles Oric (ex: `"`, `#`, `!`) et suppression transparente de Maj pour les chiffres AZERTY.
  - File d'injection automatique de texte (`typein`) pour l'exécution fluide de commandes au boot.
- **Gestion des cassettes (.TAP)** :
  - Analyseur de conteneurs .TAP standards (blocs de synchronisation, en-têtes 9 octets, adresses de début et fin).
  - Injection directe ultra-rapide (fast-load instantané) avec mise à jour automatique des pointeurs BASIC (`TXTTAB`, `VARTAB`, `ARYTAB`, `STREND`) et auto-run direct.
  - Pièges logiciels sur les routines ROM (`TAPESYNC` et `GETTAPEBYTE`) pour les chargements turbo multi-blocs.
  - Glisser-déposer de fichiers `.tap` directement sur la fenêtre de l'émulateur.
- **Suite de tests & diagnostics matériels intégrée (`test.tap`)** :
  - Programme autonome en code machine 6502 validant 13 suites de tests : jeu d'instructions complet (151 opcodes, modes d'adressage, BCD, pile), timers et registres du VIA 6522, registres et synthèse audio de l'AY-3-8912, mémoire texte et attributs couleur de l'ULA.
  - Retour visuel en temps réel sur l'écran Oric Atmos et carillon de confirmation sonore.

---

## 📁 Structure du Projet

```text
z6502/
├── build.zig                 # Script de compilation Zig 0.16 (binaire, tests, liaison SDL2 et libc)
├── build.zig.zon             # Métadonnées du paquet Zig
├── test.tap                  # Cassette de test matériel du 6502 et des coprocesseurs
├── docs/                     # Documentation technique détaillée
│   ├── tape_format.md        # Spécification complète du format cassette Oric .TAP
│   └── hardware_test.md      # Architecture et fonctionnement de la suite test.tap
├── tools/                    # Outillage Python de génération et d'assemblage
│   └── generate_test_tap.py  # Assembleur 6502 2-passes et générateur de test.tap
├── roms/                     # ROMs système Oric (atmos.rom, oric1.rom)
├── tapes/                    # Jeux, démos et cassette de test au format .tap
└── src/
    ├── main.zig              # Point d'entrée CLI, boucle SDL2, rendu vidéo & audio
    ├── root.zig              # Bibliothèque exportée et 15 tests d'intégration
    ├── cpu.zig               # Cœur CPU MOS 6502 (opcodes, modes d'adressage, BCD)
    ├── bus.zig               # Bus système (RAM 48 Ko, ROM 16 Ko, décodage d'adresses)
    ├── via.zig               # Contrôleur d'E/S MOS 6522 VIA (timers, ports, interruptions)
    ├── psg.zig               # Synthétiseur sonore AY-3-8912 & sortie audio 44.1 kHz
    ├── video.zig             # Contrôleur vidéo Ferranti ULA (texte, HIRES, attributs séries)
    ├── keyboard.zig          # Matrice clavier 8x8, mappages AZERTY/QWERTY, auto-typein
    ├── tape.zig              # Décodeur et injecteur de cassettes .TAP
    ├── oric.zig              # Machine complète (cadencement 20 000 cycles/frame à 50 Hz)
    └── sdl.zig               # Déclarations directes extern C pour SDL2
```

---

## 🛠️ Prérequis et Compilation

### Prérequis
- **Zig 0.16.0** (installé dans `~/.local/bin/zig` ou `/tmp/zig/zig`, disponible sur [https://ziglang.org/download/](https://ziglang.org/download/)).
- **libsdl2-dev** :
  ```bash
  sudo apt install libsdl2-dev
  ```

### Compilation

Pour compiler le binaire optimisé de l'émulateur :
```bash
zig build
```
L'exécutable est généré dans `zig-out/bin/z6502`.

Pour exécuter tous les tests unitaires et d'intégration (15 tests automatisés) :
```bash
zig build test
```
*Les tests vérifient la conformité du CPU (opérations BCD, pile, interruptions, jeu complet d'instructions), le boot complet sous BASIC 1.1 et 1.0 (160 frames avec test mémoire), la saisie clavier d'une commande BASIC (`PRINT 42`), la validation du son (`PING`), le chargement complet des jeux cassettes (`welcome.tap` avec option 2 interactive, `cyclotron.tap`, `stormlord.tap`, `wizards_lair.tap`), ainsi que l'exécution de la suite complète de validation matérielle (`test.tap`).*

---

## 🚀 Utilisation

### Lancer l'émulateur Oric Atmos
```bash
./zig-out/bin/z6502
```
ou directement via le système de build :
```bash
zig build run
```

### Lancer l'émulateur Oric 1
```bash
./zig-out/bin/z6502 -m oric1
```

### Lancer la suite de test matériel (CPU 6502 & Coprocesseurs)
```bash
./zig-out/bin/z6502 -t tapes/test.tap
```

### Lancer avec chargement automatique d'un jeu (.TAP)
```bash
./zig-out/bin/z6502 -t tapes/stormlord.tap
```
ou
```bash
./zig-out/bin/z6502 -t tapes/welcome.tap
```

### Options en ligne de commande

```text
Usage: z6502 [options]

Options:
  -m, --model <atmos|oric1>  Modèle à émuler (défaut: atmos)
  -r, --rom <fichier>        Chemin vers une ROM 16 Ko personnalisée
  -t, --tap <fichier>        Fichier cassette .TAP à charger au démarrage
  -s, --scale <1..6>         Facteur d'agrandissement de la fenêtre (défaut: 3)
  -w, --warp                 Mode Warp (sans limitation à 50 Hz, vitesse maximale)
  -u, --mute                 Désactiver la sortie audio
  -h, --help                 Afficher l'aide
```

---

## 🔬 Suite de Test Matériel & Coprocesseurs (`test.tap`)

La cassette [`tapes/test.tap`](file:///home/philippe/dev/z6502/tapes/test.tap) (ou [`test.tap`](file:///home/philippe/dev/z6502/test.tap)) fournit un diagnostic autonome complet en code machine 6502 :

1. **13 suites de validation** :
   - Suites 1 à 10 : Registres, transferts, ALU binaire (`ADC`/`SBC` avec overflow V et carry C), comparaisons (`CMP`/`CPX`/`CPY`), logique (`AND`/`ORA`/`EOR`), décalages/rotations (`ASL`/`LSR`/`ROL`/`ROR`), arithmétique décimale BCD (`SED`/`CLD`), branchements conditionnels, pile (`PHA`/`PLA`/`PHP`/`PLP`), sous-routines (`JSR`/`RTS`) et test de bits (`BIT`).
   - Suite 11 : Coprocesseur **VIA 6522** (registres de direction `DDRA`/`DDRB`, décrémentation des timers T1 et T2, registre d'interruption `IER`).
   - Suite 12 : Coprocesseur sonore **AY-3-8912** (programmation des registres de tonalité, bruit, mixeur, volume et enveloppe via le VIA, avec carillon sonore de confirmation à 3 notes).
   - Suite 13 : Contrôleur vidéo **ULA** (lecture/écriture de la mémoire écran `$BB80..$BFDF` et attributs série couleur).
2. **Interface à l'écran** : Affichage en direct de chaque test avec attribut vert `[PASS]` ou rouge `[FAIL]`, et bannière de succès.
3. **Contrat en Page Zéro** :
   - `$0050` = `00` si tout a réussi (ou l'index de la suite en échec).
   - `$0051` = `0D` (13 suites validées sur 13).
4. **Régénération / Extension** : Le script [`tools/generate_test_tap.py`](file:///home/philippe/dev/z6502/tools/generate_test_tap.py) permet de modifier ou enrichir les tests à volonté.

---

## 📚 Documentation Technique

Des spécifications techniques approfondies sont disponibles dans le dossier [`docs/`](file:///home/philippe/dev/z6502/docs/) :

- [**`docs/tape_format.md`**](file:///home/philippe/dev/z6502/docs/tape_format.md) : Spécification complète du format de cassette Oric `.TAP` (enregistrement physique FSK vs conteneur logique, séquence de synchronisation `0x16 0x16 0x16 0x24`, en-tête 9 octets gros-boutiste, conventions BASIC/Code Machine, routines ROM `$E735`/`$E6C9`, fast-load par injection RAM ou interception de traps, et script Python de référence).
- [**`docs/hardware_test.md`**](file:///home/philippe/dev/z6502/docs/hardware_test.md) : Manuel d'architecture et de mise en œuvre de la suite de test matériel `test.tap` (plan mémoire, détail des 13 suites, interface écran et registres de retour).

---

## ⌨️ Raccourcis Clavier

| Raccourci | Action |
|:---|:---|
| **F1** | Afficher l'état du système (registres CPU, PC, SP, mode vidéo) dans le terminal |
| **F12** / **Ctrl+F3** | Réinitialiser (Reset) la machine |
| **F4** | Basculer le mode Warp (vitesse maximale sans synchronisation 50 Hz) |
| **F5** | Basculer instantanément entre **Oric Atmos** (BASIC 1.1) et **Oric 1** (BASIC 1.0) |
| **F6** | Basculer la disposition du clavier entre **AZERTY** et **QWERTY** |
| **Glisser-Déposer** | Glisser un fichier `.tap` sur la fenêtre pour le charger et l'exécuter |

---

## 🎮 Compatibilité des Cassettes (.TAP)

L'émulateur inclut un jeu complet de cassettes d'époque dans le répertoire `tapes/` :
- `test.tap` : Cassette officielle de diagnostic CPU 6502 et coprocesseurs (VIA, AY, ULA).
- `welcome.tap` : Cassette de démonstration officielle Tangerine (graphismes HIRES, musique de bienvenue).
- `cyclotron.tap` : Jeu d'action arcade en code machine.
- `stormlord.tap` : Jeu d'aventure graphique HIRES avancé.
- `wizards_lair.tap` : Jeu culte multi-blocs.
- `xenon_1.tap`, `invaders.tap`, `harrier_attack.tap`, `aigle_dor.tap`, `hopper.tap`, etc.
