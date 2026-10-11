# shellcheck shell=bash
# upstream_wine_version PKG_VERSION: WineHQ package version -> upstream release (git tag wine-<x>)
#   11.0.0.0~noble-1 -> 11.0 ; 10.0.1.0~noble-1 -> 10.0.1
upstream_wine_version() {
    local v=${1%%~*}
    while [[ "$v" == *.*.* && "$v" == *.0 ]]; do
        v=${v%.0}
    done
    printf '%s\n' "$v"
}
