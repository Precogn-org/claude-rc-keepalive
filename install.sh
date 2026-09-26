#!/usr/bin/env bash
# Installe claude-rc-keepalive pour l'utilisateur courant (aucun droit administrateur).
# N'ACTIVE ni ne DÉMARRE RIEN : aucune session n'est créée (voir `claude-rc-ctl create`).
#
# Usage : ./install.sh [--dry-run]
#   --dry-run   affiche exactement ce qui serait fait, sans rien écrire
set -euo pipefail

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage : $0 [--dry-run]" >&2; exit 64 ;;
esac

SRC=$(cd "$(dirname "$0")" && pwd)
CFG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
LIB="$HOME/.local/lib/claude-rc"
BIN="$HOME/.local/bin"
CONF="$CFG_HOME/claude-rc"
UNITS="$CFG_HOME/systemd/user"
SESSIONS="$HOME/claude-rc/sessions"

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

echo "Installation de claude-rc-keepalive (dry-run=$DRY)"
run mkdir -p "$BIN" "$UNITS"                # dossiers PARTAGÉS : jamais modifiés (création seulement si absents)
run mkdir -p -m 700 "$LIB" "$CONF" "$HOME/claude-rc" "$SESSIONS"   # NOS dossiers : privés (700)...
run chmod 700 "$LIB" "$CONF" "$HOME/claude-rc" "$SESSIONS"         # ...même s'ils existaient déjà plus larges (réinstallation)
for f in claude-rc-ensure claude-rc-run claude-rc-ctl; do run install -m 755 "$SRC/bin/$f" "$LIB/$f"; done
run install -m 644 "$SRC/lib/common.sh" "$LIB/common.sh"
run ln -sf "$LIB/claude-rc-ctl" "$BIN/claude-rc-ctl"
for u in claude-rc@.service claude-rc@.timer; do run install -m 644 "$SRC/systemd/user/$u" "$UNITS/$u"; done

# Exemple de configuration (jamais actif : seuls les fichiers *.env sont des sessions). Jamais écrasé.
if [ -e "$CONF/session.env.example" ]; then
  echo "  exemple existant conservé : $CONF/session.env.example"
else
  run install -m 600 "$SRC/conf/session.env.example" "$CONF/session.env.example"
fi
run systemctl --user daemon-reload

cat <<MSG

Fichiers installés. AUCUNE session n'existe, RIEN n'est démarré ni activé.
Créer une session (exemple) :
  claude-rc-ctl create mon-projet --name "Nom affiché" --dir $SESSIONS/mon-projet
  claude-rc-ctl fresh  mon-projet --yes      # première session, demandée explicitement
  claude-rc-ctl enable mon-projet            # démarrage automatique (reprise par --continue)
  claude-rc-ctl list
Désinstallation : ./uninstall.sh   (les sessions en cours ne sont PAS arrêtées)
MSG
