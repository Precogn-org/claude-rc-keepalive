#!/usr/bin/env bash
# claude-rc-keepalive : fonctions communes. À « sourcer », pas à exécuter.
# Licence : MIT (voir LICENSE)
#
# Variables d'environnement reconnues (surtout pour les tests) :
#   CLAUDE_RC_CONFIG_DIR    dossier des fichiers <id>.env   (défaut : ~/.config/claude-rc)
#   CLAUDE_RC_STATE_DIR     journaux, verrous, drapeaux     (défaut : ~/.local/state/claude-rc)
#   CLAUDE_RC_NOW           heure forcée en secondes
#   CLAUDE_RC_SCREEN_FILE   texte d'écran forcé (remplace `tmux capture-pane`)

: "${CLAUDE_RC_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-rc}"
: "${CLAUDE_RC_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/claude-rc}"

rc_now() { if [ -n "${CLAUDE_RC_NOW:-}" ]; then echo "$CLAUDE_RC_NOW"; else date +%s; fi; }

# Horloge MONOTONE (secondes) pour mesurer des durées : insensible aux corrections de l'heure système
# (fréquentes juste après un démarrage, quand l'heure est recalée). rc_now reste l'heure réelle (fenêtre anti-boucle).
rc_mono() { local up; if [ -r /proc/uptime ]; then read -r up _ < /proc/uptime; echo "${up%.*}"; else date +%s; fi; }

# Tout ce que ces scripts ÉCRIVENT dans le dossier d'état est en 600/700, quel que soit l'umask de l'utilisateur.
# (Le umask n'est PAS changé pour le reste du script : tmux et claude héritent de l'umask normal.)
rc_mkstate() { ( umask 077; mkdir -p "$CLAUDE_RC_STATE_DIR" ) && chmod 700 "$CLAUDE_RC_STATE_DIR" 2>/dev/null || true; }
rc_append()  { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s\n' "$*" >> "$f" ); }
rc_write()   { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s' "$*" > "$f" ); }

# rc_log NIVEAU message...   -> une ligne horodatée (UTC) dans <état>/<id>.log
rc_log() {
  local level=$1; shift
  rc_append "$CLAUDE_RC_STATE_DIR/${RC_ID:-claude-rc}.log" "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
}

# rc_note NIVEAU ETAT message...   -> journalise seulement quand l'ETAT change (évite 1 ligne par minute)
rc_note() {
  local level=$1 state=$2; shift 2
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.last"
  if [ "$(cat "$f" 2>/dev/null || true)" != "$state" ]; then
    rc_log "$level" "$*"
    rc_write "$f" "$state"
  fi
}

# rc_load_config ID -> charge <config>/<ID>.env et pose les variables RC_*.
# Codes : 64 identifiant invalide, 65 mode de permission refusé, 66 configuration absente,
#         67 nom ou dossier déjà utilisé par une autre instance, 68 nom de session invalide.
rc_load_config() {
  RC_ID=${1:-}
  case "$RC_ID" in
    ''|*[!a-z0-9._-]*) echo "identifiant invalide : '$RC_ID' (minuscules, chiffres, . _ - seulement)" >&2; return 64 ;;
  esac
  local f="$CLAUDE_RC_CONFIG_DIR/$RC_ID.env"
  [ -r "$f" ] || { echo "configuration introuvable : $f" >&2; return 66; }
  # Le fichier est du shell : il appartient à l'utilisateur et n'est jamais modifié par ces scripts.
  # shellcheck disable=SC1090
  . "$f"
  : "${RC_NAME:?RC_NAME manquant dans $f}"
  : "${RC_DIR:?RC_DIR manquant dans $f}"
  RC_DIR=${RC_DIR%/}
  RC_PERMISSION_MODE=${RC_PERMISSION_MODE:-acceptEdits}
  CLAUDE_BIN=${CLAUDE_BIN:-$HOME/.local/bin/claude}
  RC_TMUX_SESSION=${RC_TMUX_SESSION:-rc-$RC_ID}
  RC_CONTINUE_FAIL_SECONDS=${RC_CONTINUE_FAIL_SECONDS:-45}
  RC_MAX_LAUNCHES=${RC_MAX_LAUNCHES:-3}
  RC_LAUNCH_WINDOW=${RC_LAUNCH_WINDOW:-600}
  RC_STOP_WAIT=${RC_STOP_WAIT:-20}
  # Pas d'espace ni de caractère spécial dans le nom : la détection du processus se fait sur sa ligne de commande.
  case "$RC_NAME" in
    *[!A-Za-z0-9._-]*) echo "RC_NAME invalide : '$RC_NAME' (lettres, chiffres, . _ - seulement, sans espace)" >&2; return 68 ;;
  esac
  # Liste blanche volontairement courte : jamais de bypassPermissions, ni de dontAsk, ni d'auto.
  case "$RC_PERMISSION_MODE" in
    default|acceptEdits|plan) ;;
    *) echo "mode de permission refusé : '$RC_PERMISSION_MODE' (autorisés : default, acceptEdits, plan)" >&2; return 65 ;;
  esac
  RC_STOP_FLAG="$CLAUDE_RC_STATE_DIR/$RC_ID.stop"
  RC_LAUNCHES="$CLAUDE_RC_STATE_DIR/$RC_ID.launches"
  rc_check_unique "$f" || return 67
  return 0
}

# Deux instances ne doivent partager NI le nom NI le dossier : --continue est lié au dossier, et la détection
# du processus au nom ; un partage ferait reprendre ou doubler la mauvaise session.
rc_check_unique() {
  local self=$1 other o_name o_dir
  for other in "$CLAUDE_RC_CONFIG_DIR"/*.env; do
    [ -e "$other" ] && [ "$other" != "$self" ] || continue
    o_name=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_NAME:-}" )
    o_dir=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_DIR:-}" )
    o_dir=${o_dir%/}
    if [ "$o_name" = "$RC_NAME" ]; then echo "RC_NAME '$RC_NAME' déjà utilisé par $(basename "$other")" >&2; return 1; fi
    if [ "$o_dir" = "$RC_DIR" ]; then echo "RC_DIR '$RC_DIR' déjà utilisé par $(basename "$other")" >&2; return 1; fi
  done
  return 0
}

rc_escape_ere() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# PID(s) du serveur `claude remote-control --name <RC_NAME>` de l'utilisateur courant.
# Détection par le processus (et non par le nom de la session tmux) : une session lancée à la main
# est ainsi « adoptée » au lieu d'être doublée.
rc_server_pids() {
  local name; name=$(rc_escape_ere "$RC_NAME")
  pgrep -u "$(id -u)" -f "^([^ ]*/)?claude remote-control --name ${name}( |\$)" 2>/dev/null || true
}

# API Anthropic joignable ? (toute réponse HTTP suffit ; seule une panne réseau/DNS/TLS échoue)
rc_network_ok() { curl -sS -o /dev/null -m 8 --connect-timeout 5 https://api.anthropic.com/ >/dev/null 2>&1; }

# Connexion Claude valide ? (claude auth status affiche du JSON avec "loggedIn": true)
rc_auth_ok() { "$CLAUDE_BIN" auth status 2>/dev/null | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'; }

# Verrou non bloquant par instance : empêche deux exécutions simultanées (minuteur + commande manuelle)
# de lancer chacune une session. Sans `flock` (util-linux), pas de verrou.
# Le descripteur 9 ne doit PAS être hérité par tmux : le lancement se fait avec « 9>&- ».
rc_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  rc_mkstate
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.lock"
  ( umask 077; : >> "$f" ) 2>/dev/null   # créé en 600 s'il n'existe pas...
  chmod 600 "$f" 2>/dev/null || true      # ...et resserré s'il existait déjà plus large
  exec 9>>"$f" || return 0
  flock -n 9
}

# Texte de l'écran du panneau tmux courant (les messages d'erreur de claude y sont affichés).
rc_screen() {
  if [ -n "${CLAUDE_RC_SCREEN_FILE:-}" ]; then cat "$CLAUDE_RC_SCREEN_FILE" 2>/dev/null; return 0; fi
  [ -n "${TMUX_PANE:-}" ] && tmux capture-pane -p -J -S -200 -t "$TMUX_PANE" 2>/dev/null
  return 0
}

# Garde-fou anti-boucle : au plus RC_MAX_LAUNCHES lancements par fenêtre glissante de RC_LAUNCH_WINDOW secondes.
# Au-delà, une pause (code 4) ; elle se lève d'elle-même quand les lancements les plus anciens sortent de la fenêtre.
rc_launch_allowed() {
  local now cutoff kept=0 t tmp
  now=$(rc_now); cutoff=$((now - RC_LAUNCH_WINDOW))
  rc_mkstate
  [ -f "$RC_LAUNCHES" ] || ( umask 077; : > "$RC_LAUNCHES" )
  tmp=$( umask 077; mktemp "$RC_LAUNCHES.XXXXXX" )
  while read -r t; do
    if [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge "$cutoff" ]; then echo "$t" >> "$tmp"; kept=$((kept + 1)); fi
  done < "$RC_LAUNCHES"
  mv "$tmp" "$RC_LAUNCHES"
  [ "$kept" -lt "$RC_MAX_LAUNCHES" ]
}
rc_record_launch() { rc_append "$RC_LAUNCHES" "$(rc_now)"; }
