#!/usr/bin/env bash
# Essais automatiques de claude-rc-keepalive. AUCUN vrai claude, tmux, curl ni pgrep n'est appelé :
# de faux exécutables (« stubs ») sont placés en tête du PATH, dans un dossier temporaire supprimé à la fin.
# À lancer sous Linux (ou WSL) : quelques essais (droits de fichiers, verrou flock) sont ignorés ailleurs.
# Usage : bash tests/run-tests.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'pkill -f "claude-rc-test-bg-$$" 2>/dev/null; rm -rf "$T"' EXIT
STUBS="$T/stubs"; mkdir -p "$STUBS" "$T/home" "$T/config"
LINUX=0; [ "$(uname -s)" = Linux ] && LINUX=1

export HOME="$T/home"
export CLAUDE_RC_CONFIG_DIR="$T/config" CLAUDE_RC_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" SCREEN="$T/screen.txt"
export PATH="$STUBS:$PATH"

# ---------- faux exécutables ----------
cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$STUB_LOG"
case "${1:-}" in
  auth)
    if [ "${STUB_AUTH:-ok}" = ok ]; then printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'
    else printf '{\n  "loggedIn": false\n}\n'; fi
    exit 0 ;;
  remote-control)
    if printf '%s\n' "$@" | grep -qx -- '--continue'; then sleep "${STUB_CONTINUE_SLEEP:-0}"; exit "${STUB_CONTINUE_RC:-0}"
    else exit "${STUB_FRESH_RC:-0}"; fi ;;
esac
EOF
cat > "$STUBS/curl"  <<'EOF'
#!/usr/bin/env bash
[ "${STUB_NET:-ok}" = ok ]
EOF
cat > "$STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_ALIVE:-0}" = 1 ] && { echo 4242; exit 0; }
exit 1
EOF
cat > "$STUBS/tmux"  <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
case "${1:-}" in
  has-session) exit "${STUB_TMUX_HAS:-1}" ;;
  new-session) [ -n "${STUB_TMUX_SLEEP:-}" ] && sleep "$STUB_TMUX_SLEEP"
               [ -n "${STUB_TMUX_BG:-}" ] && { ( exec -a "claude-rc-test-bg-$PPID_MARK" sleep 5 ) >/dev/null 2>&1 & }
               exit "${STUB_TMUX_NEW_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUBS"/*

# ---------- configuration de test ----------
cat > "$CLAUDE_RC_CONFIG_DIR/t1.env" <<EOF
RC_NAME="T1"
RC_DIR="$T/work"
CLAUDE_BIN="$STUBS/claude"
RC_CONTINUE_FAIL_SECONDS=3
EOF
cat > "$T/bypass.env" <<EOF
RC_NAME="B"
RC_DIR="$T/workb"
RC_PERMISSION_MODE="bypassPermissions"
EOF

ENSURE="$ROOT/bin/claude-rc-ensure"; RUN="$ROOT/bin/claude-rc-run"; CTL="$ROOT/bin/claude-rc-ctl"
pass=0; fail=0; skip=0
check() { local name=$1; shift; if "$@"; then echo "  ok     $name"; pass=$((pass + 1)); else echo "  ECHEC  $name"; fail=$((fail + 1)); fi; }
skipped() { echo "  ignoré $1"; skip=$((skip + 1)); }
reset() { rm -rf "$CLAUDE_RC_STATE_DIR" "$T/work"; : > "$STUB_LOG"; rm -f "$SCREEN" "$CLAUDE_RC_CONFIG_DIR"/t2.env "$CLAUDE_RC_CONFIG_DIR"/t3.env
          unset STUB_AUTH STUB_NET STUB_ALIVE STUB_CONTINUE_RC STUB_CONTINUE_SLEEP STUB_FRESH_RC STUB_TMUX_HAS STUB_TMUX_SLEEP STUB_TMUX_BG CLAUDE_RC_NOW CLAUDE_RC_SCREEN_FILE RC_FORCE_FRESH RC_STOP_WAIT; }
n() { grep -c -- "$1" "$STUB_LOG" || true; }               # nombre d'appels contenant le motif
logged() { grep -q -- "$1" "$CLAUDE_RC_STATE_DIR/t1.log" 2>/dev/null; }
exit_is() { local want=$1; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }
screen() { printf '%s\n' "$1" > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"; }
NOREC='Error: No recent session found in this directory or its worktrees. Run `claude remote-control` to start a new one.'

echo "== configuration"
reset
cp "$T/bypass.env" "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "mode bypassPermissions refusé (code 65)"                   exit_is 65 bash "$ENSURE" bypass
rm -f "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "identifiant invalide refusé (code 64)"                     exit_is 64 bash "$ENSURE" "Bad ID"
check "configuration absente (code 66)"                           exit_is 66 bash "$ENSURE" inconnu
printf 'RC_NAME="a b"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom de session avec espace refusé (code 68)"               exit_is 68 bash "$ENSURE" t2
printf 'RC_NAME="T1"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom déjà utilisé par une autre instance (code 67)"         exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/work/"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "dossier déjà utilisé (même avec « / » final) (code 67)"    exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "deux instances aux noms et dossiers distincts : acceptées" exit_is 0 bash "$ENSURE" t2
rm -f "$CLAUDE_RC_CONFIG_DIR/t2.env"

echo "== claude-rc-ensure : décisions"
reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; date > "$CLAUDE_RC_STATE_DIR/t1.stop"
check "arrêt volontaire : rien n'est lancé (code 0)"              exit_is 0 bash "$ENSURE" t1
check "arrêt volontaire : tmux non appelé"                        test "$(n 'new-session')" = 0
check "arrêt volontaire : journalisé"                             logged "arrêt volontaire actif"

reset; export STUB_ALIVE=1
check "session déjà en cours, connexion OK (code 0)"              exit_is 0 bash "$ENSURE" t1
check "session en cours : aucun doublon lancé"                    test "$(n 'new-session')" = 0
check "session en cours : journalisé"                             logged "en cours"
reset; export STUB_ALIVE=1 STUB_AUTH=ko
check "session en cours mais connexion invalide (code 3)"         exit_is 3 bash "$ENSURE" t1

reset; export STUB_NET=ko
check "réseau coupé : pas de lancement, code 0"                   exit_is 0 bash "$ENSURE" t1
check "réseau coupé : tmux non appelé"                            test "$(n 'new-session')" = 0
check "réseau coupé : journalisé"                                 logged "injoignable"

reset; export STUB_AUTH=ko
check "connexion invalide : rien n'est lancé (code 3)"            exit_is 3 bash "$ENSURE" t1
check "connexion invalide : tmux non appelé"                      test "$(n 'new-session')" = 0

reset
check "cas nominal : lancement (code 0)"                          exit_is 0 bash "$ENSURE" t1
check "lancement : tmux new-session -s rc-t1"                     test "$(n 'new-session -d -s rc-t1')" = 1
check "lancement : exécute claude-rc-run (sans --fresh)"          test "$(n 'claude-rc-run t1$')" = 1
check "lancement : dossier de travail créé"                       test -d "$T/work"
check "lancement : 1 entrée dans le compteur anti-boucle"         test "$(grep -c . "$CLAUDE_RC_STATE_DIR/t1.launches")" = 1

reset; export RC_FORCE_FRESH=1
check "RC_FORCE_FRESH=1 : le lancement porte --fresh"             bash -c "bash '$ENSURE' t1 && grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"

reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "anti-boucle : 3 lancements en 10 min -> pause (code 4)"    exit_is 4 bash "$ENSURE" t1
check "anti-boucle : tmux non appelé"                             test "$(n 'new-session')" = 0
export CLAUDE_RC_NOW=1600
check "anti-boucle : 10 min plus tard -> reprise AUTOMATIQUE"     exit_is 0 bash "$ENSURE" t1
check "anti-boucle : lancement effectif"                          test "$(n 'new-session')" = 1

echo "== verrou (deux exécutions simultanées)"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; export STUB_TMUX_SLEEP=1
  for i in 1 2 3; do bash "$ENSURE" t1 >/dev/null 2>&1 & done; wait
  check "3 exécutions simultanées : UN SEUL lancement"            test "$(n 'new-session')" = 1
  reset; export STUB_TMUX_BG=1 PPID_MARK=$$
  bash "$ENSURE" t1 >/dev/null 2>&1
  check "le verrou n'est pas hérité par tmux (libre après la fin)" flock -n "$CLAUDE_RC_STATE_DIR/t1.lock" true
else skipped "verrou : flock ou Linux indisponible"; fi

echo "== claude-rc-run : reprise et repli selon le MESSAGE"
reset; export STUB_CONTINUE_RC=0; mkdir -p "$T/work"
check "--continue réussit (code 0)"                               exit_is 0 bash "$RUN" t1
check "--continue réussi : un seul appel remote-control"          test "$(n 'remote-control')" = 1
check "--continue réussi : l'appel contient --continue"           test "$(n 'acceptEdits --continue')" = 1
check "--continue réussi : le nom et le mode sont transmis"       test "$(n 'remote-control --name T1 --permission-mode acceptEdits')" = 1

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "$NOREC"
check "« No recent session found » : repli (code 0)"              exit_is 0 bash "$RUN" t1
check "repli : deux appels remote-control"                        test "$(n 'remote-control')" = 2
check "repli : le second appel n'a PAS --continue"                test "$(grep 'remote-control' "$STUB_LOG" | tail -1 | grep -c -- '--continue' || true)" = 0
check "repli : journalisé (NOUVELLE session)"                     logged "NOUVELLE session"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "Error: Session session_x has no environment_id. It may never have been attached to a bridge."
check "« has no environment_id » : repli (2 appels)"              bash -c "bash '$RUN' t1; test \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 2"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Error: Session session_x is already being served by another \`claude remote-control\` instance (pid 4242) in /tmp/x. Use that terminal, or stop it first."
check "« already being served » : code 5"                         exit_is 5 bash "$RUN" t1
check "« already being served » : AUCUNE nouvelle session"        test "$(n 'remote-control')" = 1
check "« already being served » : journalisé en ERROR"            logged "ERROR.*déjà servie"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Error: Another \`claude remote-control\` instance (pid 7) is already running in this directory. Exiting to avoid a split-brain conflict."
check "course « split-brain » : code 5, aucune nouvelle session"  bash -c "bash '$RUN' t1; [ \$? -eq 5 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Resuming session session_abc (16m ago)…"
check "reprise engagée puis arrêt rapide : PAS de nouvelle session" bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Error: quelque chose d'imprévu (HTTP 503)"
check "erreur inconnue : code 6"                                  exit_is 6 bash "$RUN" t1
check "erreur inconnue : AUCUNE nouvelle session"                 test "$(n 'remote-control')" = 1
check "erreur inconnue : le message est journalisé"               logged "HTTP 503"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; : > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"
check "écran vide (pas de message) : traité comme inconnu (6)"    exit_is 6 bash "$RUN" t1

reset; export STUB_CONTINUE_RC=1 STUB_NET=ko; mkdir -p "$T/work"; screen "$NOREC"
check "« No recent session » mais réseau coupé : pas de repli"    bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"
check "réseau coupé : journalisé"                                 logged "injoignable"

reset; export STUB_CONTINUE_RC=1 STUB_CONTINUE_SLEEP=4; mkdir -p "$T/work"; screen "$NOREC"
check "échec APRÈS longtemps : jamais de repli, même avec ce message" bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; mkdir -p "$T/work"
check "--fresh : un seul appel, sans --continue"                  bash -c "bash '$RUN' t1 --fresh; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ] && ! grep -q -- '--continue' '$STUB_LOG'"

echo "== claude-rc-ctl"
reset
check "ctl stop : crée le drapeau"                                bash -c "'$CTL' stop t1 >/dev/null 2>&1; test -e '$CLAUDE_RC_STATE_DIR/t1.stop'"
check "ctl status : affiche l'arrêt volontaire"                   bash -c "'$CTL' status t1 | grep -q 'arrêt volontaire   : OUI'"
check "ensure après stop : rien n'est lancé"                      bash -c ": > '$STUB_LOG'; '$ENSURE' t1; test \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0"
check "ctl start : retire le drapeau et lance"                    bash -c "'$CTL' start t1 >/dev/null 2>&1; test ! -e '$CLAUDE_RC_STATE_DIR/t1.stop' && grep -q 'new-session' '$STUB_LOG'"
reset
check "ctl fresh sans --yes : refusé (code 64), rien lancé"       bash -c "! '$CTL' fresh t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
reset
check "ctl fresh --yes : lance avec --fresh"                      bash -c "'$CTL' fresh t1 --yes >/dev/null 2>&1; grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"
reset; export STUB_ALIVE=1 RC_STOP_WAIT=2
check "ctl stop : signale l'échec si le serveur ne disparaît pas" exit_is 1 bash "$CTL" stop t1
reset; export STUB_ALIVE=1 RC_STOP_WAIT=2
check "ctl restart : n'enchaîne PAS un lancement si l'ancien serveur survit" bash -c "! bash '$CTL' restart t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"

echo "== permissions (umask 0002, comme sur le VPS)"
if [ "$LINUX" = 1 ]; then
  reset
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "dossier d'état en 700"                                   test "$(stat -c %a "$CLAUDE_RC_STATE_DIR")" = 700
  check "journal en 600"                                          test "$(stat -c %a "$CLAUDE_RC_STATE_DIR/t1.log")" = 600
  check "fichier d'état (.last) en 600"                           test "$(stat -c %a "$CLAUDE_RC_STATE_DIR/t1.last")" = 600
  check "compteur de lancements en 600"                           test "$(stat -c %a "$CLAUDE_RC_STATE_DIR/t1.launches")" = 600
  check "le dossier de travail garde l'umask normal (775)"        test "$(stat -c %a "$T/work")" = 775
else skipped "permissions : Linux requis"; fi

echo "== verrou et dossiers d'installation : droits"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "verrou créé en 600 (umask 0002)"                         test "$(stat -c %a "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
  reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; ( umask 0002; : > "$CLAUDE_RC_STATE_DIR/t1.lock" ); chmod 664 "$CLAUDE_RC_STATE_DIR/t1.lock"
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "verrou existant en 664 : resserré en 600"                test "$(stat -c %a "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
else skipped "droits du verrou : Linux + flock requis"; fi
if [ "$LINUX" = 1 ]; then
  cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"; exit 0
EOF
  chmod +x "$STUBS/systemctl"
  H2="$T/home2"; mkdir -p "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.local/bin" "$H2/.config/systemd/user"
  chmod 775 "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.config/systemd/user"; chmod 755 "$H2/.local/bin"
  ( umask 0002; HOME="$H2" XDG_CONFIG_HOME="$H2/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (dossiers existants en 775) : ~/.config/claude-rc resserré en 700"   test "$(stat -c %a "$H2/.config/claude-rc")" = 700
  check "install (dossiers existants en 775) : ~/.local/lib/claude-rc resserré en 700" test "$(stat -c %a "$H2/.local/lib/claude-rc")" = 700
  check "install : ~/.local/bin (dossier partagé) INCHANGÉ (755)"                    test "$(stat -c %a "$H2/.local/bin")" = 755
  check "install : ~/.config/systemd/user (dossier partagé) INCHANGÉ (775)"          test "$(stat -c %a "$H2/.config/systemd/user")" = 775
  check "install : configuration en 600"                                             test "$(stat -c %a "$H2/.config/claude-rc/test-vps-cli.env")" = 600
  check "install : unités en 644 et scripts en 755"                                  bash -c "[ \"\$(stat -c %a '$H2/.config/systemd/user/claude-rc@.timer')\" = 644 ] && [ \"\$(stat -c %a '$H2/.local/lib/claude-rc/claude-rc-run')\" = 755 ]"
  H3="$T/home3"; mkdir -p "$H3"
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (HOME neuf, umask 0002) : ~/.config/claude-rc créé en 700"          test "$(stat -c %a "$H3/.config/claude-rc")" = 700
  check "install (HOME neuf, umask 0002) : ~/.local/lib/claude-rc créé en 700"       test "$(stat -c %a "$H3/.local/lib/claude-rc")" = 700
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "réinstallation : les dossiers restent en 700"                               bash -c "[ \"\$(stat -c %a '$H3/.config/claude-rc')\" = 700 ] && [ \"\$(stat -c %a '$H3/.local/lib/claude-rc')\" = 700 ]"
else skipped "droits des dossiers d'installation : Linux requis"; fi

echo "== détection du processus (motif utilisé par pgrep -f, testé sur de vraies lignes de commande)"
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
match() { local name=$1 line=$2 re; re="^([^ ]*/)?claude remote-control --name $(rc_escape_ere "$name")( |\$)"; printf '%s\n' "$line" | grep -Eq -- "$re"; }
nomatch() { ! match "$@"; }
check "reconnaît « claude remote-control --name X … »"           match "TEST-VPS-CLI" "claude remote-control --name TEST-VPS-CLI --permission-mode acceptEdits"
check "reconnaît le chemin absolu de claude"                      match "TEST-VPS-CLI" "/home/u/.local/bin/claude remote-control --name TEST-VPS-CLI --permission-mode acceptEdits --continue"
check "reconnaît le nom en fin de ligne"                          match "TEST-VPS-CLI" "claude remote-control --name TEST-VPS-CLI"
check "ne confond pas avec le processus tmux qui le contient"     nomatch "TEST-VPS-CLI" "tmux new-session -d -s rc claude remote-control --name TEST-VPS-CLI"
check "ne confond pas TEST-VPS-CLI avec TEST-VPS-CLI-2"           nomatch "TEST-VPS-CLI" "claude remote-control --name TEST-VPS-CLI-2"
check "ne confond pas TEST-VPS avec TEST-VPS-CLI"                 nomatch "TEST-VPS" "claude remote-control --name TEST-VPS-CLI"
check "échappe les caractères spéciaux du nom (A.B)"              match "A.B" "claude remote-control --name A.B --permission-mode plan"
check "le « . » n'est pas un joker (A.B ≠ AxB)"                   nomatch "A.B" "claude remote-control --name AxB --permission-mode plan"

echo "== installation"
check "install.sh --dry-run : code 0"                             exit_is 0 bash "$ROOT/install.sh" --dry-run
check "install.sh --dry-run : n'écrit RIEN"                       test ! -e "$T/home/.local" -a ! -e "$T/home/.config"
check "install.sh --dry-run : annonce les unités"                 bash -c "'$ROOT/install.sh' --dry-run | grep -q 'claude-rc@.timer'"
check "uninstall.sh --dry-run : code 0 et n'écrit rien"           bash -c "'$ROOT/uninstall.sh' --dry-run >/dev/null && test ! -e '$T/home/.local'"
check "install.sh / uninstall.sh : ni kill, ni tmux, ni stop"     bash -c "! grep -nE '\\b(kill|pkill|tmux|restart)\\b|systemctl.* stop' '$ROOT/install.sh' '$ROOT/uninstall.sh'"

echo "== unités systemd et hygiène"
S="$ROOT/systemd/user/claude-rc@.service"; M="$ROOT/systemd/user/claude-rc@.timer"
check "service : Type=oneshot"                                    grep -q '^Type=oneshot' "$S"
check "service : KillMode=process (tmux survit)"                  grep -q '^KillMode=process' "$S"
check "service : ExecStart vers claude-rc-ensure %i"              grep -q '^ExecStart=%h/.local/lib/claude-rc/claude-rc-ensure %i' "$S"
check "service : PATH explicite avec ~/.local/bin"                grep -q '^Environment=PATH=%h/.local/bin' "$S"
check "service : ne démarre pas sans fichier de configuration"    grep -q '^ConditionPathExists=%E/claude-rc/%i.env' "$S"
check "service : pas de UMask forcé (tmux et claude héritent de l'umask normal)" bash -c "! grep -q '^UMask=' '$S'"
check "minuteur : OnBootSec=60s"                                  grep -q '^OnBootSec=60s' "$M"
check "minuteur : OnUnitInactiveSec=60s"                          grep -q '^OnUnitInactiveSec=60s' "$M"
check "minuteur : AccuracySec=1s"                                 grep -q '^AccuracySec=1s' "$M"
check "minuteur : RandomizedDelaySec=10s (démarrage étalé)"       grep -q '^RandomizedDelaySec=10s' "$M"
check "minuteur : WantedBy=timers.target"                         grep -q '^WantedBy=timers.target' "$M"
for f in bin/claude-rc-ensure bin/claude-rc-run bin/claude-rc-ctl lib/common.sh install.sh uninstall.sh tests/run-tests.sh; do
  check "syntaxe bash : $f"                                       bash -n "$ROOT/$f"
done
echo "== hygiène du dépôt avant publication (détail : tests/hygiene.sh)"
check "hygiène : aucune clé, IPv4, e-mail ni longue chaîne aléatoire, ni terme de la liste personnelle" bash "$ROOT/tests/hygiene.sh"
[ -f "$ROOT/tests/private-patterns.local" ] || skipped "liste personnelle absente (tests/private-patterns.local) : À CRÉER avant de publier"

echo
echo "Résultat : $pass réussi(s), $fail échec(s), $skip ignoré(s)"
[ "$fail" -eq 0 ]
