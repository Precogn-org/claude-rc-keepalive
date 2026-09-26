# claude-rc-keepalive

🇬🇧 [English](README.md) · 🇫🇷 Français

Garde **une session Claude Code Remote Control** en vie sur une machine Linux toujours allumée (VPS, mini-PC) :
elle est relancée après un arrêt ou un redémarrage, et **reprend la même session claude.ai** quand c'est possible,
pour continuer à la piloter depuis le téléphone, la tablette ou claude.ai/code.

> **Statut : prototype, une session.** Testé avec Claude Code 2.1.282 sur Ubuntu 24.04, y compris un vrai restart et un vrai
> reboot. Plusieurs points importants ne sont pas encore vérifiés (limite des 4 heures, réseau tardif au démarrage…) : voir [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md).
> Ce projet n'est ni affilié à Anthropic ni soutenu par elle. Version anglaise : [README.md](README.md).
> Les messages de journal et les commentaires du code sont pour l'instant en français ; la documentation est bilingue.

## Pourquoi

`claude remote-control` est un processus **local** : s'il s'arrête (redémarrage, panne réseau prolongée, plantage),
la session passe « hors ligne » et rien ne la relance. La documentation officielle recommande `tmux` ou `screen`
sur une machine distante, mais ne décrit ni démarrage automatique ni supervision. Ce dépôt en fournit une version
minimale : quelques scripts shell et deux unités systemd **utilisateur** (aucun droit administrateur).

## Comment ça marche

```
   démarrage de la machine ─(60 s)─┐        toutes les minutes ─┐
                                    ▼                            ▼
                          claude-rc@<id>.timer ───────► claude-rc@<id>.service (oneshot, ~1 s)
                                                                 │  claude-rc-ensure <id>
                                                                 ▼
        déjà en cours de vérification ? ─oui─► laisser faire       (verrou flock)
        arrêt volontaire ? ─oui─► ne rien faire                   (drapeau <id>.stop)
        serveur déjà là ? ─oui─► vérifier la connexion Claude     (une session lancée à la main est ADOPTÉE)
        API joignable ? ─non─► attendre                           (jamais de session « par erreur » à cause du réseau)
        connexion Claude valide ? ─non─► journaliser, sortie 3
        trop de lancements récents ? ─oui─► pause, sortie 4       (reprend seule)
                 │
                 ▼
        tmux new-session ─► claude-rc-run <id>
                                 └─ claude remote-control --name … --continue                (même session claude.ai)
                                         │ échec : le MESSAGE affiché décide (le code de sortie est toujours 1)
                                         ├─ « No recent session found » / « has no environment_id » ─► nouvelle session
                                         ├─ « already being served / already running »               ─► rien (doublon évité)
                                         └─ tout autre message                                       ─► rien (décision humaine)
```

Pourquoi lire le message : `--continue` sort avec le code 1 aussi bien quand il n'y a **rien à reprendre** que quand
**la session est déjà servie** par un autre processus. Traiter tout échec comme « il faut une nouvelle session » créerait
des doublons. Tous les messages connus sont dans [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md).

## Prérequis

- Linux avec **systemd** (gestionnaire utilisateur), `tmux`, `curl`, `bash`, `pgrep`, `flock` (util-linux ; sans lui,
  pas de verrou).
- [Claude Code](https://code.claude.com/docs/en/quickstart) installé et **connecté** (`claude auth login`, compte claude.ai :
  Pro, Max, Team ou Enterprise ; les clés d'API ne fonctionnent pas avec Remote Control).
- `loginctl enable-linger <utilisateur>` (vérifier : `loginctl show-user $USER -p Linger` → `Linger=yes`), sinon le
  minuteur ne démarre qu'à la première connexion.
- Un dossier de travail déjà **approuvé** par Claude Code (dialogue « trust ») pour la session.

## Arborescence

Dans le dépôt :

```
bin/claude-rc-ensure      vérifie / relance (appelé par le minuteur)
bin/claude-rc-run         exécuté dans tmux : --continue puis, selon le message, nouvelle session
bin/claude-rc-ctl         status | start | stop | restart | fresh | logs | screen
lib/common.sh             fonctions communes
systemd/user/claude-rc@.service   unité « modèle » (oneshot, KillMode=process)
systemd/user/claude-rc@.timer     minuteur « modèle » (60 s après le démarrage, puis chaque minute)
conf/test-vps-cli.env.example     exemple de configuration d'une session
install.sh / uninstall.sh         (--dry-run disponible)
tests/run-tests.sh                essais automatiques avec de faux claude/tmux/curl
tests/hygiene.sh                  balayage avant publication (clés, IPv4, e-mails, termes personnels)
docs/VERIFIED.fr.md                  vérifié / non vérifié, messages de Claude Code
```

Créés par `install.sh` (dans le répertoire de l'utilisateur uniquement) :

| Chemin | Droits | Rôle |
|---|---|---|
| `~/.local/lib/claude-rc/` (4 fichiers) | dossier **700**, scripts 755, `common.sh` 644 | scripts |
| `~/.local/bin/claude-rc-ctl` | lien symbolique | commande |
| `~/.config/systemd/user/claude-rc@.service`, `claude-rc@.timer` | 644 | unités |
| `~/.config/claude-rc/` et `test-vps-cli.env` | dossier **700**, fichier **600** (jamais écrasé) | configuration |

Créés à l'exécution, **tous en 600 dans un dossier 700** : `~/.local/state/claude-rc/<id>.{log,last,launches,stop,lock}`.
Les dossiers partagés (`~/.local/bin`, `~/.config/systemd/user`) ne sont jamais modifiés.

## Installation

```bash
./install.sh --dry-run          # affiche tout ce qui serait fait, n'écrit rien
./install.sh                    # copie les fichiers, ne démarre RIEN, n'arrête RIEN
$EDITOR ~/.config/claude-rc/test-vps-cli.env     # nom, dossier de travail, mode de permission
systemctl --user enable --now claude-rc@test-vps-cli.timer
claude-rc-ctl status test-vps-cli
```

Une session **déjà lancée à la main** avec le même nom (`--name`) est **adoptée** : le minuteur la voit vivante et n'y
touche pas ; il ne prendra le relais qu'à son prochain arrêt.

## Désinstallation

```bash
./uninstall.sh --dry-run
./uninstall.sh                  # supprime unités et scripts ; la session en cours N'EST PAS arrêtée
./uninstall.sh --purge          # supprime aussi configurations et journaux
```

## Utilisation courante

```bash
claude-rc-ctl status  <id>      # état, connexion Claude, dernières lignes du journal
claude-rc-ctl stop    <id>      # arrêt VOLONTAIRE : le minuteur ne relancera pas tant que vous ne faites pas start
claude-rc-ctl start   <id>      # retire l'arrêt volontaire et lance (reprise --continue)
claude-rc-ctl restart <id>      # arrête le processus (et attend qu'il ait disparu), relance avec --continue
claude-rc-ctl fresh   <id> --yes   # NOUVELLE session (l'ancienne reste hors ligne dans claude.ai : à archiver)
claude-rc-ctl logs    <id> 100  # journal
claude-rc-ctl screen  <id>      # écran actuel de la session (lecture seule)
tmux attach -t rc-<id>          # voir/piloter la session dans un terminal (Ctrl-b d pour quitter)
```

## Codes de sortie de `claude-rc-ensure`

| Code | Sens |
|---|---|
| 0 | tout va bien (en cours, lancée, arrêt volontaire, réseau absent, ou vérification déjà en cours) |
| 1 | tmux n'a pas démarré / dossier de travail impossible à créer |
| 3 | connexion Claude invalide : rien n'est lancé (le service apparaît « failed ») |
| 4 | pause anti-boucle (3 lancements en 10 min) ; **reprend seule** quand la fenêtre est écoulée |
| 64-68 | configuration invalide (identifiant, mode refusé, absente, nom/dossier déjà pris, nom de session invalide) |

`claude-rc-run` : code de claude, ou **5** (session déjà servie par une autre instance), ou **6** (échec inconnu de `--continue`).

## Que se passe-t-il quand…

- **la machine redémarre** : le gestionnaire utilisateur démarre (grâce au linger), le minuteur se déclenche ~60 s après
  le démarrage (au plus +10 s de décalage). Le dossier de travail est recréé s'il a disparu (`/tmp` est vidé à chaque
  démarrage). Si le réseau n'est pas encore là, le script attend et réessaie chaque minute sans rien lancer.
- **`--continue` réussit** (arrêt de moins d'environ 4 h, session encore connue du serveur) : **même session claude.ai**,
  même conversation. Le serveur est alors en mode « session unique » ; quand la session se termine, il s'arrête et le
  minuteur le reprend à la minute suivante.
- **rien à reprendre** (« No recent session found », par exemple après plus de 4 h) et API joignable : **nouvelle
  session** du même nom. L'ancienne reste « hors ligne » dans claude.ai/code : archivez-la.
- **la session est déjà servie** par un autre processus (message « already being served ») : **aucune nouvelle session**,
  sortie 5. Cas typique : un redémarrage manuel trop rapide (`claude-rc-ctl restart` attend la disparition de l'ancien).
- **erreur inconnue** (réseau, serveur…) : **aucune nouvelle session**, sortie 6, le message est journalisé ; le
  minuteur réessaie (dans la limite de 3 lancements par 10 minutes). Si la session est définitivement perdue :
  `claude-rc-ctl fresh <id> --yes`.
- **la connexion Claude expire** : rien n'est lancé, une erreur claire est journalisée et le service échoue
  (`systemctl --user --failed`). Refaites `claude auth login`.
- **plusieurs instances** : chacune a son fichier `<id>.env`, sa session tmux (`rc-<id>`), son journal, son verrou et son
  compteur. Deux instances **ne peuvent pas** partager le même `RC_NAME` ni le même `RC_DIR` (refus, code 67).
  Le minuteur étale ses déclenchements de 10 s au plus. Comptez environ 300 Mo de mémoire par session.

## Sécurité

- Aucun droit administrateur, aucun port ouvert : Remote Control fait des connexions **sortantes** uniquement.
- Aucun secret dans ce dépôt ni dans les fichiers de configuration ; la connexion est celle de `claude auth login`
  (`~/.claude/.credentials.json`, droits 600) : ces scripts **ne lisent jamais ce fichier** et n'appellent que
  `claude auth status`.
- Modes de permission autorisés : `default`, `acceptEdits`, `plan`. **`bypassPermissions`, `auto` et `dontAsk` sont refusés**
  par le script. Une session pilotée à distance peut exécuter des commandes sur la machine : choisissez le dossier de
  travail et les droits du compte en conséquence.
- Le fichier `<id>.env` est chargé comme du code shell : il doit appartenir à l'utilisateur et n'être modifiable que par lui
  (600).
- Les fichiers d'état sont en 600 dans un dossier 700, quel que soit l'`umask`. L'`umask` normal est conservé pour tmux et
  claude (les fichiers que la session crée gardent les droits habituels).

## Limites connues

- **Une instance = un dossier de travail = un nom de session**, tous uniques (`--continue` est lié au dossier).
- Après une reprise, le serveur est en mode **« session unique »** : pas de nouvelles sessions depuis le téléphone.
- Avec `KillMode=process`, `tmux` et `claude` restent dans le groupe de processus du service terminé, et systemd écrit un
  avertissement « Found left-over process … Ignoring » à chaque passage. Sans danger mais bruyant ; une conception plus
  propre est prévue (voir [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md)).
- Les noms de session n'acceptent pour l'instant que lettres, chiffres, `.`, `_` et `-` (pas d'espace).
- La fenêtre de reprise (~4 h) et un reboot avec réseau tardif ne sont **pas vérifiés**.

## Tests

```bash
bash tests/run-tests.sh          # sous Linux (ou WSL) ; environ 100 essais
```

Les essais utilisent de faux `claude`, `tmux`, `curl` et `pgrep` : ils ne touchent ni au réseau, ni à une vraie session.
Ils ne remplacent pas un essai réel, notamment un redémarrage (voir [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md)). Sous Windows
(Git Bash), les essais de droits et de verrou sont ignorés.

**Avant de publier un fork ou une contribution :** `bash tests/hygiene.sh` balaie les clés, adresses IPv4, e-mails et longues chaînes aléatoires. Pour y
ajouter vos propres termes à ne jamais publier (noms, projets, hôtes), créez `tests/private-patterns.local` (un motif
par ligne). Ce fichier est dans `.gitignore` et ne doit **jamais** être commité.

## Licence

MIT (voir [LICENSE](LICENSE)).
