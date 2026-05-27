[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Dépôt :** https://github.com/ps81frt/gestion-logistique
# gestion-logistique.sh

Script bash de gestion des droits d'installation logistique via polkit sur Linux Mint et Ubuntu.  
Accorde ou révoque à un utilisateur la capacité d'installer, désinstaller et mettre à jour des paquets (PackageKit, Flatpak, aptkit) sans passer par sudo.

---

## Prérequis

### Système
- Linux Mint 20+ ou Ubuntu 20.04+
- systemd
- polkit 0.105+

### Dépendances binaires
Toutes vérifiées au démarrage du script. Présentes par défaut sur Mint/Ubuntu.

| Binaire | Rôle |
|---|---|
| `groupadd` | Création du groupe logistique |
| `usermod` | Ajout de l'utilisateur au groupe |
| `gpasswd` | Retrait de l'utilisateur du groupe |
| `groupdel` | Suppression du groupe si vide |
| `systemctl` | Redémarrage du service polkit |
| `logger` | Écriture dans le journal systemd |
| `getent` | Lecture de la base de groupes |
| `sha256sum` | Intégrité des fichiers de backup |
| `flock` | Verrouillage exclusif contre les exécutions concurrentes |

---

## Installation

Aucune installation requise. Le script s'exécute directement.

```bash
sudo bash gestion-logistique.sh install <utilisateur>
```

Le script doit être exécuté en root (`sudo` ou session root).

---

## Usage

```
sudo bash gestion-logistique.sh <action> <utilisateur>
sudo bash gestion-logistique.sh --dry-run <action> <utilisateur>
```

### Actions disponibles

| Action | Effet |
|---|---|
| `install` | Crée le groupe `logistique` si absent, ajoute l'utilisateur, écrit la règle polkit, redémarre polkit |
| `revert` | Retire l'utilisateur du groupe, supprime groupe et règle si plus aucun membre |
| `rollback` | Restaure le dernier backup de la règle polkit (vérifie le checksum SHA256 si disponible) |

### Option

| Option | Effet |
|---|---|
| `--dry-run` | Simule toutes les actions sans modifier le système. Affiche la règle polkit qui serait générée. |

### Exemples

```bash
# Accorder les droits à l'utilisateur jean
sudo bash gestion-logistique.sh install jean

# Révoquer les droits
sudo bash gestion-logistique.sh revert jean

# Restaurer la dernière règle polkit sauvegardée
sudo bash gestion-logistique.sh rollback jean

# Simuler un install sans rien appliquer
sudo bash gestion-logistique.sh --dry-run install jean
```

---

## Variables configurables

En haut du script, modifiables sans toucher au reste du code.

| Variable | Valeur par défaut | Description |
|---|---|---|
| `POLKIT_GROUP` | `logistique` | Nom du groupe système créé pour les droits d'installation |
| `POLKIT_RULE_FILE` | `/etc/polkit-1/rules.d/99-logistique-install.rules` | Chemin de la règle polkit générée |
| `POLKIT_RULE_DIR` | `/etc/polkit-1/rules.d` | Répertoire des règles polkit |
| `OS_RELEASE` | `/etc/os-release` | Fichier de détection de la distribution |
| `MAX_BACKUPS` | `5` | Nombre maximum de fichiers `.bak` conservés avant purge automatique |
| `LOCK_FILE` | `/var/lock/gestion-logistique.lock` | Fichier de verrou pour empêcher les exécutions simultanées |

---

## Ce que fait le script en détail

### `install`

1. Crée le groupe `logistique` (`groupadd -f` — idempotent)
2. Ajoute l'utilisateur au groupe (`usermod -aG`)
3. Génère la règle polkit dans un fichier temporaire (`mktemp`)
4. Sauvegarde l'ancienne règle si elle existe (`.bak` + `.bak.sha256`)
5. Purge les backups excédant `MAX_BACKUPS`
6. Déplace la règle en place de façon atomique (`mv`)
7. Redémarre polkit

> **Note :** La prise en compte du nouveau groupe nécessite une déconnexion/reconnexion de l'utilisateur.

### `revert`

1. Retire l'utilisateur du groupe (`gpasswd -d`)
2. Vérifie si le groupe a encore des membres (`getent`)
3. Invalide le cache NSS (`nscd`, `systemd-userdbd`)
4. Si groupe vide : supprime le groupe et la règle polkit
5. Si groupe non vide : conserve la règle, log les membres restants
6. Redémarre polkit

### `rollback`

1. Trouve le backup le plus récent via `find` + `sort` (robuste aux espaces dans les noms)
2. Vérifie l'intégrité SHA256 si le fichier `.sha256` est présent
3. Restaure la règle polkit
4. Redémarre polkit et invalide le cache NSS

> **Note :** Le rollback restaure uniquement la règle polkit. L'appartenance au groupe de l'utilisateur n'est pas modifiée.

---

## Fichiers créés par le script

| Fichier | Description |
|---|---|
| `/etc/polkit-1/rules.d/99-logistique-install.rules` | Règle polkit active |
| `*.bak` | Backup horodaté de la règle (`YYYYMMDD_HHMMSS`) |
| `*.bak.sha256` | Checksum SHA256 du backup correspondant |
| `/var/lock/gestion-logistique.lock` | Verrou d'exécution exclusive |

---

## Actions polkit accordées

### Linux Mint uniquement

| Action | Description |
|---|---|
| `org.aptkit.install-or-remove-packages` | Installation/suppression via aptkit (Mint 21+) |
| `org.aptkit.upgrade-packages` | Mise à jour via aptkit |
| `com.linuxmint.updates.apply-updates` | Gestionnaire de mises à jour Mint |
| `org.freedesktop.packagekit.system-sources-refresh` | Rafraîchissement des sources |

### Linux Mint et Ubuntu

| Action | Description |
|---|---|
| `org.freedesktop.packagekit.package-install` | Installation de paquets |
| `org.freedesktop.packagekit.package-remove` | Suppression de paquets |
| `org.freedesktop.packagekit.package-install-untrusted` | Installation de paquets non signés |
| `org.freedesktop.packagekit.system-update` | Mise à jour système |
| `org.freedesktop.Flatpak.app-install` | Installation d'application Flatpak |
| `org.freedesktop.Flatpak.app-uninstall` | Suppression d'application Flatpak |
| `org.freedesktop.Flatpak.app-update` | Mise à jour d'application Flatpak |
| `org.freedesktop.Flatpak.runtime-install` | Installation de runtime Flatpak |
| `org.freedesktop.Flatpak.system-install` | Installation système Flatpak |
| `org.freedesktop.Flatpak.system-uninstall` | Suppression système Flatpak |

---

## Logs

Toutes les actions sont journalisées via `logger` avec le tag `gestion-logistique`.

```bash
# Consulter les logs
journalctl -t gestion-logistique

# Suivre en temps réel
journalctl -f -t gestion-logistique
```

---

## Debug & vérification

### Vérifier que la règle est active

```bash
# Lister les règles polkit en place
ls -la /etc/polkit-1/rules.d/

# Inspecter la règle générée
grep -A10 "isInGroup" /etc/polkit-1/rules.d/99-logistique-install.rules
```

### Vérifier les actions polkit disponibles

```bash
# Mint
pkaction --action-id org.aptkit.install-or-remove-packages --verbose

# Mint et Ubuntu
pkaction --action-id org.freedesktop.packagekit.package-install --verbose
pkaction --action-id org.freedesktop.Flatpak.app-install --verbose
```

### Vérifier l'appartenance au groupe

```bash
groups <utilisateur>
getent group logistique
```

### Tester une autorisation

```bash
sudo -u <utilisateur> pkcheck \
  --action-id org.freedesktop.packagekit.package-install \
  --process $$
```

### Observer les décisions polkit en temps réel

```bash
journalctl -f -t polkitd
```

### Vérifier l'intégrité d'un backup manuellement

```bash
sha256sum -c /etc/polkit-1/rules.d/99-logistique-install.rules.YYYYMMDD_HHMMSS.bak.sha256
```

---

## Codes de sortie

| Code | Signification |
|---|---|
| `0` | Succès |
| `1` | Erreur : root manquant, dépendance absente, utilisateur invalide ou inexistant, verrou occupé, checksum invalide, service polkit introuvable |

---

## Sécurité

- Le nom d'utilisateur est validé par regex `^[a-z_][a-z0-9_-]{0,31}$` avant toute utilisation
- La règle polkit est écrite de façon atomique (pas de fichier partiel en cas d'interruption)
- Le verrou `flock` empêche deux exécutions simultanées de corrompre la règle
- Les backups sont signés SHA256 et vérifiés avant tout rollback
- La règle polkit n'accorde les droits qu'aux sessions locales et actives (`subject.local && subject.active`)
