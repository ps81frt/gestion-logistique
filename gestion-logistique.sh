#!/bin/bash
# =============================================================================
# Nom        : gestion-logistique.sh
# Version    : 1.2
# Auteur     : ps81frt
# Date       : 2026-05-28
# Rôle       : Accorder / révoquer les droits d'installation logistique via polkit
# Cible      : Linux Mint / Ubuntu (systemd + polkit)
# Dépôt      : https://github.com/ps81frt/gestion-logistique
# Licence    : MIT
# -----------------------------------------------------------------------------
# Usage :
#   sudo bash gestion-logistique.sh install     <utilisateur>   # Accorder les droits
#   sudo bash gestion-logistique.sh revert      <utilisateur>   # Révoquer les droits
#   sudo bash gestion-logistique.sh rollback    <utilisateur>   # Restaurer dernière règle
#   sudo bash gestion-logistique.sh --dry-run install <utilisateur>  # Simulation sans modification
# -----------------------------------------------------------------------------
# Options :
#   --dry-run    Exécuter en mode simulation : affiche les actions sans les appliquer
# -----------------------------------------------------------------------------
# Dépendances requises :
#   groupadd, usermod, gpasswd, groupdel, systemctl, logger, getent,
#   sha256sum (intégrité des backups), flock (verrouillage exclusif)
# -----------------------------------------------------------------------------
# Sécurité & robustesse :
#   • Verrouillage exclusif via flock : empêche les exécutions concurrentes
#   • Backups signés SHA256 : vérification d'intégrité avant rollback
#   • Écriture atomique des règles : mktemp + mv pour éviter la corruption
#   • Mode --dry-run : validation sans impact sur le système
# -----------------------------------------------------------------------------
# Debug & vérifications :
#   • Vérifier les actions Polkit disponibles :
#       [Mint] pkaction --action-id org.aptkit.install-or-remove-packages --verbose
#       [Mint] pkaction --action-id org.aptkit.upgrade-packages --verbose
#       [Mint] pkaction --action-id com.linuxmint.updates.apply-updates --verbose
#       [Mint] pkaction --action-id org.freedesktop.packagekit.system-sources-refresh --verbose
#       [Both] pkaction --action-id org.freedesktop.packagekit.package-install --verbose
#       [Both] pkaction --action-id org.freedesktop.packagekit.package-remove --verbose
#       [Both] pkaction --action-id org.freedesktop.packagekit.package-install-untrusted --verbose
#       [Both] pkaction --action-id org.freedesktop.packagekit.system-update --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.app-install --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.app-uninstall --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.app-update --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.runtime-install --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.system-install --verbose
#       [Both] pkaction --action-id org.freedesktop.Flatpak.system-uninstall --verbose
#
#   • Observer les décisions polkit en temps réel :
#       journalctl -f -t polkitd
#
#   • Vérifier l'appartenance au groupe logistique :
#       groups <utilisateur>
#       getent group logistique
#
#   • Lister les règles polkit actives :
#       ls -la /etc/polkit-1/rules.d/
#
#   • Inspecter la règle chargée :
#       grep -A10 "isInGroup" /etc/polkit-1/rules.d/99-logistique-install.rules
#
#   • Tester une autorisation pour un utilisateur :
#       sudo -u <utilisateur> pkcheck --action-id org.freedesktop.packagekit.package-install --process $$
#
#   • Vérifier l'intégrité d'un backup :
#       sha256sum -c /etc/polkit-1/rules.d/99-logistique-install.rules.YYYYMMDD_HHMMSS.bak.sha256
# -----------------------------------------------------------------------------
# Sorties :
#   0  : Succès
#   1  : Erreur (root manquant, dépendance, utilisateur invalide, verrou occupé, etc.)
# =============================================================================

set -euo pipefail

POLKIT_GROUP="logistique"
POLKIT_RULE_FILE="/etc/polkit-1/rules.d/99-logistique-install.rules"
POLKIT_RULE_DIR="/etc/polkit-1/rules.d"
OS_RELEASE="/etc/os-release"
MAX_BACKUPS=5
LOCK_FILE="/var/lock/gestion-logistique.lock"

DRY_RUN=false

ACTION="${1:?Usage: sudo bash gestion-logistique.sh [--dry-run] <install|revert|rollback> <utilisateur>}"
if [[ "$ACTION" == "--dry-run" ]]; then
    DRY_RUN=true
    ACTION="${2:?Usage: sudo bash gestion-logistique.sh --dry-run <install|revert|rollback> <utilisateur>}"
    TARGET_USER="${3:?Usage: sudo bash gestion-logistique.sh --dry-run <install|revert|rollback> <utilisateur>}"
else
    TARGET_USER="${2:?Usage: sudo bash gestion-logistique.sh <install|revert|rollback> <utilisateur>}"
fi

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
    local -a required=(groupadd usermod gpasswd groupdel systemctl logger getent sha256sum flock)
    local req
    for req in "${required[@]}"; do
        if ! command -v "$req" >/dev/null 2>&1; then
            echo "ERREUR : dependance requise manquante : $req" >&2
            exit 1
        fi
    done
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "ERREUR : une autre instance est en cours d execution (verrou : $LOCK_FILE)" >&2
        exit 1
    fi
}

check_user_exists() {
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "ERREUR : utilisateur '$TARGET_USER' inexistant" >&2
        exit 1
    fi
}

validate_user() {
    if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "ERREUR : nom d utilisateur invalide : '$TARGET_USER'" >&2
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
    local candidates=("polkit" "polkitd")
    for svc in "${candidates[@]}"; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}"; then
            echo "$svc"
            return 0
        fi
    done
    for svc in "${candidates[@]}"; do
        if systemctl cat "${svc}.service" &>/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    echo "ERREUR : service polkit introuvable" >&2
    return 1
}

reload_polkit() {
    local svc
    svc="$(get_polkit_service)" || exit 1
    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN : systemctl restart $svc (simulé)"
        return 0
    fi
    if ! systemctl restart "$svc" 2>/dev/null; then
        echo "ERREUR : impossible de recharger polkit" >&2
        exit 1
    fi
}

backup_rule() {
    if [ -f "$POLKIT_RULE_FILE" ]; then
        local ts
        ts="$(date '+%Y%m%d_%H%M%S')"
        if [ "$DRY_RUN" = true ]; then
            log "DRY-RUN : sauvegarde -> ${POLKIT_RULE_FILE}.${ts}.bak (simulé)"
            return 0
        fi
        cp "$POLKIT_RULE_FILE" "${POLKIT_RULE_FILE}.${ts}.bak"
        sha256sum "${POLKIT_RULE_FILE}.${ts}.bak" >"${POLKIT_RULE_FILE}.${ts}.bak.sha256"
        log "INFO : sauvegarde -> ${POLKIT_RULE_FILE}.${ts}.bak"
        local -a baks
        mapfile -t baks < <(find "$(dirname "$POLKIT_RULE_FILE")" -maxdepth 1 \
            -name "$(basename "$POLKIT_RULE_FILE").*.bak" -printf '%T@ %p\n' 2>/dev/null |
            sort -rn | awk '{print $2}')
        local count="${#baks[@]}"
        if [ "$count" -gt "$MAX_BACKUPS" ]; then
            for ((i = MAX_BACKUPS; i < count; i++)); do
                rm -f "${baks[$i]}" "${baks[$i]}.sha256"
                log "INFO : backup supprime (limite $MAX_BACKUPS) : ${baks[$i]}"
            done
        fi
    fi
}

flush_nss_cache() {
    if command -v nscd >/dev/null 2>&1; then
        nscd --invalidate=group 2>/dev/null || true
    fi
    if systemctl is-active systemd-userdbd >/dev/null 2>&1; then
        systemctl kill -s SIGHUP systemd-userdbd 2>/dev/null || true
    fi
}

build_allowed_lines() {
    local -a lines=()

    if is_linux_mint; then
        lines+=('"org.aptkit.install-or-remove-packages"')
        lines+=('"org.aptkit.upgrade-packages"')
        lines+=('"com.linuxmint.updates.apply-updates"')
        lines+=('"org.freedesktop.packagekit.system-sources-refresh"')
    fi

    # Actions PackageKit standards (Ubuntu / Debian / Mint)
    lines+=('"org.freedesktop.packagekit.package-install"')
    lines+=('"org.freedesktop.packagekit.package-remove"')
    lines+=('"org.freedesktop.packagekit.package-install-untrusted"')
    lines+=('"org.freedesktop.packagekit.system-update"')

    # Actions Flatpak
    lines+=('"org.freedesktop.Flatpak.app-install"')
    lines+=('"org.freedesktop.Flatpak.app-uninstall"')
    lines+=('"org.freedesktop.Flatpak.app-update"')
    lines+=('"org.freedesktop.Flatpak.runtime-install"')
    lines+=('"org.freedesktop.Flatpak.system-install"')
    lines+=('"org.freedesktop.Flatpak.system-uninstall"')

    local out=""
    local last_idx=$((${#lines[@]} - 1))
    for i in "${!lines[@]}"; do
        local sep=","
        [ "$i" -eq "$last_idx" ] && sep=""
        out+="        ${lines[$i]}${sep}"$'\n'
    done
    printf '%s' "$out"
}

write_rule() {
    local allowed_lines
    allowed_lines="$(build_allowed_lines)"
    local tmp_file
    tmp_file="$(mktemp)"

    mkdir -p "$POLKIT_RULE_DIR"
    backup_rule

    cat >"$tmp_file" <<EOF
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

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN : règle polkit générée (non appliquée) :"
        cat "$tmp_file"
        rm -f "$tmp_file"
        return 0
    fi

    chmod 644 "$tmp_file"
    mv "$tmp_file" "$POLKIT_RULE_FILE"
}

cmd_install() {
    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN : groupadd -f $POLKIT_GROUP (simulé)"
        log "DRY-RUN : usermod -aG $POLKIT_GROUP $TARGET_USER (simulé)"
        write_rule
        reload_polkit
        return 0
    fi
    groupadd -f "$POLKIT_GROUP"
    usermod -aG "$POLKIT_GROUP" "$TARGET_USER"
    write_rule
    reload_polkit
    log "OK : $TARGET_USER ajoute au groupe $POLKIT_GROUP"
    echo "INFO : deconnexion / reconnexion requise pour prise en compte"
}

cmd_revert() {
    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN : gpasswd -d $TARGET_USER $POLKIT_GROUP (simulé)"
        local remaining
        remaining="$(getent group "$POLKIT_GROUP" 2>/dev/null | cut -d: -f4 || echo "")"
        if [ -z "$remaining" ] || [ "$remaining" = "$TARGET_USER" ]; then
            log "DRY-RUN : groupe vide après retrait — groupe et règle seraient supprimés"
        else
            log "DRY-RUN : groupe conservé pour [$remaining] — règle maintenue"
        fi
        reload_polkit
        return 0
    fi
    gpasswd -d "$TARGET_USER" "$POLKIT_GROUP" 2>/dev/null || true
    log "OK : $TARGET_USER retire du groupe $POLKIT_GROUP"

    local remaining
    remaining="$(getent group "$POLKIT_GROUP" 2>/dev/null | cut -d: -f4 || echo "")"

    flush_nss_cache

    if [ -z "$remaining" ]; then
        groupdel "$POLKIT_GROUP" 2>/dev/null || true
        rm -f "$POLKIT_RULE_FILE"
        log "OK : groupe et regle supprimes"
    else
        log "INFO : groupe utilise par [$remaining], regle conservee"
    fi

    reload_polkit
    log "OK : droits revoques pour $TARGET_USER"
}

cmd_rollback() {
    local latest
    latest="$(find "$(dirname "$POLKIT_RULE_FILE")" -maxdepth 1 \
        -name "$(basename "$POLKIT_RULE_FILE").*.bak" -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | awk 'NR==1{print $2}')"

    if [ -z "$latest" ]; then
        echo "ERREUR : aucun backup disponible" >&2
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN : restauration de $latest vers $POLKIT_RULE_FILE (simulée)"
        log "DRY-RUN : reload_polkit + flush_nss_cache (simulés)"
        return 0
    fi

    if [ -f "${latest}.sha256" ]; then
        if ! sha256sum -c "${latest}.sha256" >/dev/null 2>&1; then
            echo "ERREUR : checksum invalide pour $latest — backup corrompu" >&2
            exit 1
        fi
        log "INFO : intégrité du backup vérifiée"
    else
        log "WARN : pas de checksum disponible pour $latest — restauration sans vérification"
    fi

    cp "$latest" "$POLKIT_RULE_FILE"
    chmod 644 "$POLKIT_RULE_FILE"

    reload_polkit
    flush_nss_cache
    log "OK : rollback applique depuis $latest"
    log "OK : $TARGET_USER reconnecter pour prise en compte"
}

check_root
check_dependencies
check_os_release
validate_user
check_user_exists
acquire_lock

case "$ACTION" in
install) cmd_install ;;
revert) cmd_revert ;;
rollback) cmd_rollback ;;
*)
    echo "ERREUR : action inconnue '$ACTION'" >&2
    echo "Usage : sudo bash gestion-logistique.sh [--dry-run] <install|revert|rollback> <utilisateur>" >&2
    exit 1
    ;;
esac
