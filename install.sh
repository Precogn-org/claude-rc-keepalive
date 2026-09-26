#!/usr/bin/env bash
# Installe claude-rc-keepalive pour l'utilisateur courant (aucun droit administrateur).
# N'ACTIVE RIEN : l'activation du minuteur est une commande séparée, affichée à la fin.
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

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

echo "Installation de claude-rc-keepalive (dry-run=$DRY)"
run mkdir -p "$BIN" "$UNITS"                # dossiers PARTAGÉS : jamais modifiés (création seulement si absents)
run mkdir -p -m 700 "$LIB" "$CONF"          # NOS dossiers : privés (700)...
run chmod 700 "$LIB" "$CONF"                # ...même s'ils existaient déjà plus larges (réinstallation)
for f in claude-rc-ensure claude-rc-run claude-rc-ctl; do run install -m 755 "$SRC/bin/$f" "$LIB/$f"; done
run install -m 644 "$SRC/lib/common.sh" "$LIB/common.sh"
run ln -sf "$LIB/claude-rc-ctl" "$BIN/claude-rc-ctl"
for u in claude-rc@.service claude-rc@.timer; do run install -m 644 "$SRC/systemd/user/$u" "$UNITS/$u"; done

if [ -e "$CONF/test-vps-cli.env" ]; then
  echo "  configuration existante conservée : $CONF/test-vps-cli.env"
else
  run install -m 600 "$SRC/conf/test-vps-cli.env.example" "$CONF/test-vps-cli.env"
fi
run systemctl --user daemon-reload

cat <<EOF

Fichiers installés. RIEN n'est encore activé. Pour activer la session « test-vps-cli » :
  systemctl --user enable --now claude-rc@test-vps-cli.timer
Puis :
  claude-rc-ctl status test-vps-cli
Désinstallation : ./uninstall.sh   (la session en cours n'est PAS arrêtée)
EOF
