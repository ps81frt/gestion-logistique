#!/bin/bash
# ==============================================================
# Nom    : gestion-logistique.sh
# Auteur : ps81frt
# Role   : Accorder / revoquer les droits d installation
#          logistique via polkit (Mint / Ubuntu)
# Usage  : sudo bash gestion-logistique.sh install  <utilisateur>
#          sudo bash gestion-logistique.sh revert   <utilisateur>
#          sudo bash gestion-logistique.sh rollback <utilisateur>
# ==============================================================
set -euo pipefail

POLKIT_GROUP="logistique"
POLKIT_RULE_FILE="/etc/polkit-1/rules.d/99-logistique-install.rules"
POLKIT_RULE_DIR="/etc/polkit-1/rules.d"
OS_RELEASE="/etc/os-release"

ACTION="${1:?Usage: sudo bash gestion-logistique.sh <install|revert|rollback> <utilisateur>}"
TARGET_USER="${2:?Usage: sudo bash gestion-logistique.sh <install|revert|rollback> <utilisateur>}"

log() {
    logger -t "gestion-logistique" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERREUR : ce script doit etre execute en root" >&2
        exit 1
    fi
}

check_dependencies() {
    local -a required=(groupadd usermod gpasswd groupdel systemctl logger getent)
    local req
    for req in "${required[@]}"; do
        if ! command -v "$req" > /dev/null 2>&1; then
            echo "ERREUR : dependance requise manquante : $req" >&2
            exit 1
        fi
    done
}

check_user_exists() {
    if ! id "$TARGET_USER" > /dev/null 2>&1; then
        echo "ERREUR : utilisateur '$TARGET_USER' inexistant" >&2
        exit 1
    fi
}

check_os_release() {
    if [ ! -f "$OS_RELEASE" ]; then
        echo "ERREUR : $OS_RELEASE introuvable" >&2
        exit 1
    fi
}

is_linux_mint() {
    grep -q "^ID=linuxmint" "$OS_RELEASE" 2>/dev/null
}

get_polkit_service() {
    if systemctl list-units --type=service 2>/dev/null | grep -q "polkitd.service"; then
        echo "polkitd"
    else
        echo "polkit"
    fi
}

reload_polkit() {
    local svc
    svc="$(get_polkit_service)"
    if ! systemctl reload "$svc" 2>/dev/null; then
        log "INFO : reload echoue, tentative restart $svc"
        if ! systemctl restart "$svc" 2>/dev/null; then
            echo "ERREUR : impossible de recharger polkit" >&2
            exit 1
        fi
    fi
}

backup_rule() {
    if [ -f "$POLKIT_RULE_FILE" ]; then
        local ts
        ts="$(date '+%Y%m%d_%H%M%S')"
        cp "$POLKIT_RULE_FILE" "${POLKIT_RULE_FILE}.${ts}.bak"
        log "INFO : sauvegarde -> ${POLKIT_RULE_FILE}.${ts}.bak"
    fi
}

flush_nss_cache() {
    if command -v nscd > /dev/null 2>&1; then
        nscd --invalidate=group 2>/dev/null || true
    fi
    if systemctl is-active systemd-userdbd > /dev/null 2>&1; then
        systemctl kill -s SIGHUP systemd-userdbd 2>/dev/null || true
    fi
}

build_allowed_lines() {
    local -a lines=()

    if is_linux_mint; then
        lines+=( '"org.aptkit.install-or-remove-packages"' )
        lines+=( '"org.aptkit.upgrade-packages"' )
        lines+=( '"com.linuxmint.updates.apply-updates"' )
    fi

    lines+=( '"org.freedesktop.packagekit.package-install"' )
    lines+=( '"org.freedesktop.packagekit.package-remove"' )
    lines+=( '"org.freedesktop.Flatpak.app-install"' )
    lines+=( '"org.freedesktop.Flatpak.app-uninstall"' )
    lines+=( '"org.freedesktop.Flatpak.runtime-install"' )
    lines+=( '"org.freedesktop.Flatpak.system-install"' )

    local out=""
    for id in "${lines[@]}"; do
        out+="        ${id},"$'\n'
    done
    printf '%s' "$out"
}

write_rule() {
    local allowed_lines
    allowed_lines="$(build_allowed_lines)"

    mkdir -p "$POLKIT_RULE_DIR"
    backup_rule

    cat > "$POLKIT_RULE_FILE" <<EOF
polkit.addRule(function(action, subject) {
    if (!subject.local || !subject.active) { return null; }
    if (!subject.isInGroup("${POLKIT_GROUP}")) { return null; }

    var allowed = [
${allowed_lines}    ];

    for (var i = 0; i < allowed.length; i++) {
        if (action.id === allowed[i]) {
            return polkit.Result.YES;
        }
    }

    return null;
});
EOF
    chmod 644 "$POLKIT_RULE_FILE"
}

cmd_install() {
    groupadd -f "$POLKIT_GROUP"
    usermod -aG "$POLKIT_GROUP" "$TARGET_USER"
    write_rule
    reload_polkit
    log "OK : $TARGET_USER ajoute au groupe $POLKIT_GROUP"
    echo "INFO : deconnexion / reconnexion requise pour prise en compte"
}

cmd_revert() {
    gpasswd -d "$TARGET_USER" "$POLKIT_GROUP" 2>/dev/null || true
    log "OK : $TARGET_USER retire du groupe $POLKIT_GROUP"

    flush_nss_cache

    local remaining
    remaining="$(getent group "$POLKIT_GROUP" 2>/dev/null | cut -d: -f4 || echo "")"

    if [ -z "$remaining" ]; then
        groupdel "$POLKIT_GROUP" 2>/dev/null || true
        rm -f "$POLKIT_RULE_FILE"
        log "OK : groupe et regle supprimes"
    else
        log "INFO : groupe utilise par $remaining, regle conservee"
    fi

    reload_polkit
    log "OK : droits revoques pour $TARGET_USER"
}

cmd_rollback() {
    local latest
    latest="$(ls -t "${POLKIT_RULE_FILE}".*.bak 2>/dev/null | head -1 || echo "")"

    if [ -z "$latest" ]; then
        echo "ERREUR : aucun backup disponible" >&2
        exit 1
    fi

    cp "$latest" "$POLKIT_RULE_FILE"
    chmod 644 "$POLKIT_RULE_FILE"

    groupadd -f "$POLKIT_GROUP"

    usermod -aG "$POLKIT_GROUP" "$TARGET_USER"

    reload_polkit
    flush_nss_cache
    log "OK : rollback applique depuis $latest"
    log "OK : $TARGET_USER reconnecter pour prise en compte"
}

check_root
check_dependencies
check_os_release
check_user_exists

case "$ACTION" in
    install)  cmd_install  ;;
    revert)   cmd_revert   ;;
    rollback) cmd_rollback ;;
    *)
        echo "ERREUR : action inconnue '$ACTION'" >&2
        echo "Usage : sudo bash gestion-logistique.sh <install|revert|rollback> <utilisateur>" >&2
        exit 1
        ;;
esac
