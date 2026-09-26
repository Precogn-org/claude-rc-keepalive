# Ce qui est vérifié, et ce qui ne l'est pas

🇬🇧 [English](VERIFIED.md) · 🇫🇷 Français

Environnement des essais : Ubuntu 24.04, Claude Code 2.1.282 (Linux x86_64), tmux 3.4, systemd 255 (gestionnaire
utilisateur avec `Linger=yes`), abonnement Claude Max, 24-26 septembre 2026. Deux machines : un serveur (VPS) pour les
essais réels de Remote Control, et un poste Windows avec WSL Ubuntu 24.04 (**vrai systemd 255**) pour les essais qui
ne devaient rien toucher au serveur (unités transitoires uniquement, jamais de fichier d'unité).

## Vérifié sur le serveur (essais réels)

| Point | Comment |
|---|---|
| `claude remote-control --name X` tourne dans tmux et reste joignable depuis l'application mobile et claude.ai/code | lancé, session pilotée depuis un téléphone, fichier écrit sur la machine |
| Un `SIGTERM` sur le serveur arrête aussi la session enfant, sans toucher aux autres processus | essai du 25/09 |
| Relancé avec `--continue` **dans le même dossier**, le serveur retrouve **la même session claude.ai** (même identifiant `cse_…`, même `environmentId`) | essai du 25/09 |
| **Un vrai reboot de la machine** : le minuteur utilisateur s'est déclenché 66 s après le démarrage, le dossier de travail a été recréé, `--continue` a repris la **même session** (mêmes `sessionId`, `environmentId`, `cse_…` ; nouveaux PID), une seule instance, aucun doublon | reboot du 26/09 (redémarrage en 9 s, session de retour ~73 s après le démarrage) |
| La conversation est conservée (`~/.claude/projects/<dossier>/*.jsonl`) et la session répond avec son contexte | question posée depuis le téléphone après la reprise |
| Après `--continue`, le serveur est en **mode « session unique »** (« Single session · exits when complete ») : plus de sessions à la demande, et il s'arrête quand la session se termine | écran observé le 25/09 |
| Un minuteur systemd de précision par défaut détecte l'arrêt en ~70 s | mesuré : 69 s (`AccuracySec=1s` est prévu) |
| `claude auth status` fonctionne sans terminal, avec un environnement minimal (`env -i`, `setsid`, stdin fermé) : code 0, ~0,4 s, aucune sortie d'erreur, **fichier d'identifiants non modifié** | essai du 26/09 |
| Les identifiants sont dans `~/.claude/.credentials.json` (droits 600) ; le jeton d'accès (8 h) est renouvelé automatiquement | fichier et date de renouvellement observés |
| `claude` n'est pas dans le PATH d'un service utilisateur (`~/.local/bin` absent) | `systemctl --user show-environment` |
| Sous Ubuntu, `/tmp` est vidé à chaque démarrage (`D /tmp 1777 root root 30d`) | `systemd-tmpfiles --cat-config` |
| Un dossier neuf sous un dossier déjà approuvé (`/tmp/…`) ne redéclenche pas le dialogue « trust » | lancement de `/tmp/test-vps-cli` |
| Le motif de détection du processus (`pgrep -f`) reconnaît le vrai serveur (chemin absolu de `claude`, `--continue` ajouté) et ignore le processus `tmux` qui le contient | essai sur le serveur, 26/09 |
| Au dernier démarrage du serveur : réseau prêt à T+8 s, gestionnaire utilisateur à T+9 s, minuteur prévu à T+60 s | `systemctl show … ActiveEnterTimestamp` |
| Les processus lancés par un service `oneshot` avec `KillMode=process` restent dans le cgroup du service (« inactive (dead) ») pendant longtemps sans être tués ; systemd écrit alors un avertissement à chaque nouveau démarrage | observé sur le serveur, 25-26/09 |

## Vérifié sur WSL avec le vrai systemd (aucune unité installée)

| Point | Résultat |
|---|---|
| `systemd-analyze --user verify` sur les unités installées | code 0, aucun avertissement ; un **témoin négatif** (unité cassée) est bien détecté |
| Service `oneshot` + tmux, `KillMode` par défaut | **la session est tuée dès la fin du script** (0 processus après 3 s) |
| Même chose avec `KillMode=process` | la session **survit** ; systemd note « Unit process … (tmux: server) remains running after unit stopped » |
| Minuteur + service `oneshot` + `KillMode=process` (essai de 11 s, passages toutes les 2-3 s) | **1 seule création**, puis des contrôles « vivant » répétés |
| Même minuteur **sans** `KillMode=process` | **une nouvelle création à chaque passage** (4 en 11 s, 0 « vivant ») |
| Arrêt du minuteur + arrêt du service + `daemon-reload` (équivalent de la désinstallation) | la session **survit** |
| `install.sh` dans un HOME fictif : fichiers et droits | dossiers 755, scripts 755, unités 644, **configuration 600**, lien symbolique ; seule commande systemctl : `daemon-reload` |
| Seconde installation | la configuration modifiée par l'utilisateur **n'est pas écrasée** |
| `install.sh` puis `uninstall.sh` avec une session simulée en cours | la session **reste vivante** (même pid) ; ni `kill`, ni `tmux`, ni `stop` dans ces scripts |
| `install` remplace un script **en cours d'exécution** | nouvel inode : le processus en cours finit normalement |
| Trois exécutions simultanées de `claude-rc-ensure` **avant** le verrou | **3 lancements** (défaut confirmé) ; **avec** le verrou `flock` : 1 seul |
| Fichiers d'état avec `umask 0002` **avant** correction | 664 (dossier 700) ; **après** correction : 600, dossier 700, dossier de travail inchangé |
| Lecture de l'écran par `tmux capture-pane -t $TMUX_PANE` avec un **vrai tmux** | les messages d'erreur de claude sont lus après la sortie du processus (4 scénarios vérifiés) |

## Vérifié sur le serveur avec la v2.2 (une vraie session, 26 septembre 2026)

| Point | Résultat |
|---|---|
| `install.sh` sur le serveur | dossiers 700, scripts 755, unités 644, exemple de configuration 600 ; **aucune session créée, rien démarré ni activé** |
| `claude-rc-ctl create` | écrit la configuration en 600 après validation ; ne démarre rien |
| Premier lancement `--fresh` dans un dossier | Claude Code pose la question interactive **« Spawn mode ? [1/2] »** et **ignore `SIGTERM` pendant l'attente** ; `--spawn same-dir` (désormais transmis pour les nouvelles sessions) évite la question |
| Session créée avec un nom contenant `/` | connectée, nom exactement celui configuré, « Capacity 1/32 … new sessions will be created in the current directory » |
| Mémoire d'une session au repos | **370 Mo** résidents (serveur 144 Mo + enfant 235 Mo) ; « disponible » du système en baisse d'environ 150 Mo (pages partagées), 6577 → 6430 Mo |
| `enable` + premier passage du minuteur | le serveur vivant a été **adopté** (pas de seconde session), une session tmux, un serveur |
| `SIGTERM` sur le serveur, sans drapeau d'arrêt | le minuteur a relancé avec `--continue` **67 s plus tard** : même `sessionId`, même `environmentId`, nouveau pid, un seul serveur |
| `claude-rc-ctl restart` pendant la pause anti-boucle (3 lancements en 10 min, provoqués par l'essai lui-même) | rien n'a été lancé (défaut, corrigé : les commandes humaines remettent le compteur à zéro) ; le minuteur a repris seul à la fin de la fenêtre (environ 4 min plus tard), mêmes `sessionId` et `environmentId` |
| Détection du serveur par le dossier de travail | le minuteur adopte le serveur dont `/proc/<pid>/cwd` est le dossier de l'instance, quel que soit son nom |
| Chargement des `CLAUDE.md` depuis un sous-dossier d'un dépôt (`claude -p`) | `~/CLAUDE.md` et le `CLAUDE.md` du dépôt (dossier parent) ont été chargés |
| `acceptEdits`, sans dossier additionnel (`claude -p`) | écrire **et lire** un fichier dans un autre projet : **refusé** |
| `acceptEdits` + `--add-dir <dossier>` | écrire dans ce dossier : **autorisé** |
| `acceptEdits` + `permissions.additionalDirectories` dans un fichier de réglages (`--settings fichier`, et `<dossier>/.claude/settings.local.json`) | écrire et lire dans un autre projet : **autorisé** |
| `CLAUDE.md` d'un dossier additionnel | chargé seulement avec `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` (set to `1`) (observé avec `claude -p`) |
| `claude remote-control --help` | **aucune option `--add-dir`** (seulement `--spawn`, `--capacity`, `--permission-mode`, `--continue`…) |
| `claude -p` lit l'entrée standard | quand un script était envoyé à `ssh … bash -s`, `claude -p` a avalé la suite du script : toujours utiliser `</dev/null` |

Reste à confirmer depuis un téléphone : qu'une session lancée par Remote Control applique le même réglage de dossiers
additionnels (mêmes sources de réglages, mais pas encore observé depuis l'appli mobile).

## Comportement de `claude remote-control` (extrait du binaire 2.1.282, à revérifier à chaque mise à jour)

Le code de sortie est **toujours 1** : seuls les messages permettent de distinguer les cas. Ils sont affichés sur l'erreur standard.

| Message (début) | Signification | Décision de `claude-rc-run` |
|---|---|---|
| `Resuming session <id> (<âge>) …` | reprise engagée (annonce avant la connexion) | jamais de nouvelle session |
| `Error: No recent session found in this directory or its worktrees.` | rien d'enregistré pour ce dossier (première fois, ou trop ancien : ~4 h) ; **sortie immédiate, avant tout appel réseau** | **rien, code 7** (`RC_FALLBACK=never` par défaut) ; nouvelle session seulement avec `RC_FALLBACK=norecord` et API joignable |
| `Error: Session <id> has no environment_id.` | session jamais rattachée à un serveur | **rien** (code 6) |
| `Error: Session <id> is already being served by another claude remote-control instance (pid N) …` | doublon : un autre processus sert déjà la session | **rien** (code 5) |
| `Error: Environment <id> is already being served by another … (pid N) …` | idem | **rien** (code 5) |
| `Error: Another claude remote-control instance (pid N) is already running in this directory. Exiting to avoid a split-brain conflict.` | course entre deux lancements | **rien** (code 5) |
| tout autre message | erreur réseau/serveur, session supprimée ou archivée… **non cartographié** | **rien** (code 6) ; décision humaine : `claude-rc-ctl fresh <id> --yes` |

## NON vérifié (à ne pas présenter comme acquis)

| Point | Pourquoi c'est important | Comment le vérifier |
|---|---|---|
| Un reboot avec **réseau tardif** | le script attend et réessaie, mais cela n'a pas été observé | redémarrer en bloquant le réseau |
| **La limite des 4 heures** (documentation : « environ 4 heures ») | valeur exacte et message réel au-delà non mesurés ; le code lit un âge de pointeur (`ageMs`) sans que son effet soit certain | arrêter, attendre plus de 4 h, relancer |
| Les messages **réseau/serveur** pendant une reprise | non cartographiés : ils tombent dans « inconnu » (aucune nouvelle session) | provoquer une coupure pendant `--continue` |
| `--continue` quand la session a été **supprimée** ou **archivée** côté claude.ai | l'archivage est annulé automatiquement (documentation) ; la suppression est inconnue | supprimer la session, relancer |
| Arrêt brutal (`SIGKILL`, coupure) | seul `SIGTERM` a été essayé | `kill -9` sur le serveur |
| Lecture de l'écran avec le **vrai** claude (et pas un simulacre qui écrit sur la sortie d'erreur) | l'interface plein écran de claude pourrait effacer les messages | échec provoqué avec le vrai claude |
| **Durée de vie de la connexion Claude** | les sessions sans surveillance s'arrêtent quand elle expire ; le script se contente de le détecter | observation sur plusieurs jours |
| `claude remote-control` **sans terminal** (directement sous systemd, sans tmux) | non essayé volontairement | test dédié, non prévu |
| Les vraies unités **modèles** (`claude-rc@.service`) chargées par le systemd du serveur | vérifiées en syntaxe et par le vrai `systemd-analyze` sur WSL, mais jamais installées | `systemd-analyze --user verify` sur le serveur, puis installation |
| Le vrai `install.sh` (hors `--dry-run`) et `uninstall.sh` **sur le serveur** | exécutés uniquement dans un HOME fictif | installer, vérifier les fichiers, désinstaller |
| Plusieurs instances réelles en parallèle | vérifié seulement par les essais avec faux exécutables (noms/dossiers distincts, verrous et compteurs par instance) | deux sessions réelles |
| Mise à jour de Claude Code pendant qu'une session tourne | comportement du serveur non observé | — |

## Limites connues, par conception

- **Une instance = un dossier de travail = un nom de session**, uniques (`--continue` est lié au dossier).
- **Mode « session unique » après reprise** : pas de nouvelles sessions depuis le téléphone.
- **Nouvelle session** seulement sur demande explicite (`claude-rc-ctl fresh <id> --yes`) ou avec `RC_FALLBACK=norecord` dans le cas « rien à reprendre » ; l'ancienne reste « hors ligne » dans claude.ai/code : à archiver.
- **`/tmp`, `/var/tmp`, `/dev/shm` et `/run`** sont refusés comme dossiers de travail (vidés au démarrage).
- **Les journaux** contiennent les décisions du script et, en cas d'échec, les dernières lignes affichées par claude.
- Avertissements `Found left-over process … Ignoring` dans le journal systemd utilisateur à chaque passage (conséquence de
  `KillMode=process`) ; une conception plus propre (tmux dans sa propre unité transitoire) n'est pas encore testée.
