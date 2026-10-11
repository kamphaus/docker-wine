# shellcheck shell=bash
# Sourced by /usr/local/bin/desktop: selects and prepares the Wine prefix (see wine-prefix init).
WINEPREFIX="$(wine-prefix init)" || die "Wine prefix initialisation failed (see messages above)"
export WINEPREFIX
log "using Wine prefix $WINEPREFIX (PREFIX_MODE=${PREFIX_MODE:-seed})"
