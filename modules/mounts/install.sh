#!/bin/bash
set -e

real_user="${SUDO_USER:-$USER}"
real_uid="${SUDO_UID:-$(id -u)}"
real_gid="${SUDO_GID:-$(id -g)}"
real_home=$(getent passwd "$real_user" | cut -d: -f6)
steam_apps="$real_home/.local/share/Steam/steamapps"

unmounted_uuids=()
unmounted_labels=()
unmounted_points=()
all_ntfs_uuids=()
all_ntfs_points=()
all_ntfs_fstypes=()

while IFS= read -r line; do
    eval "$line"

    [[ "$FSTYPE" == "ntfs" || "$FSTYPE" == "ntfs3" ]] || continue
    [[ -n "$UUID" ]] || continue

    if [[ -n "$LABEL" ]]; then
        mount_name="${LABEL,,}"
        mount_name="${mount_name// /_}"
    else
        mount_name="$NAME"
    fi

    if findmnt -rn -S "UUID=$UUID" &>/dev/null; then
        mp=$(findmnt -rn -o TARGET -S "UUID=$UUID")
        fs=$(findmnt -rn -o FSTYPE -S "UUID=$UUID")
        all_ntfs_uuids+=("$UUID")
        all_ntfs_points+=("$mp")
        all_ntfs_fstypes+=("$fs")
        continue
    fi

    unmounted_uuids+=("$UUID")
    unmounted_labels+=("${LABEL:-$NAME}")
    unmounted_points+=("/mnt/$mount_name")
done < <(lsblk -P -o NAME,FSTYPE,UUID,LABEL,MOUNTPOINT 2>/dev/null)

if [[ ${#unmounted_uuids[@]} -eq 0 ]]; then
    echo "all NTFS partitions already mounted"
else
    echo "unmounted NTFS partitions:"
    for i in "${!unmounted_uuids[@]}"; do
        echo "  ${unmounted_labels[$i]} -> ${unmounted_points[$i]}"
    done

    read -r -p "mount them? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "skipped"; exit 0; }

    for i in "${!unmounted_uuids[@]}"; do
        point="${unmounted_points[$i]}"
        uuid="${unmounted_uuids[$i]}"

        if findmnt -rn -S "UUID=$uuid" &>/dev/null; then
            echo "  $point already mounted, skipping"
            continue
        fi

        printf "  mounting %s... " "$point"
        mkdir -p "$point"

        fs_used=""
        if mount -t ntfs3 -o "uid=$real_uid,gid=$real_gid,umask=022" "UUID=$uuid" "$point" 2>/dev/null; then
            echo "ok (ntfs3)"
            fs_used="ntfs3"
        elif mount -t ntfs-3g -o "uid=$real_uid,gid=$real_gid,umask=022" "UUID=$uuid" "$point" 2>/dev/null; then
            echo "ok (ntfs-3g)"
            fs_used="ntfs-3g"
        else
            echo "failed"
        fi

        if [[ -n "$fs_used" ]]; then
            all_ntfs_uuids+=("$uuid")
            all_ntfs_points+=("$point")
            all_ntfs_fstypes+=("$fs_used")
        fi
    done
fi

for i in "${!all_ntfs_uuids[@]}"; do
    uuid="${all_ntfs_uuids[$i]}"
    point="${all_ntfs_points[$i]}"
    fs="${all_ntfs_fstypes[$i]}"
    if ! grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
        echo "UUID=$uuid $point $fs uid=$real_uid,gid=$real_gid,umask=022,nofail 0 0" >> /etc/fstab
        echo "  $point: added to /etc/fstab (auto-mount on boot)"
    fi
done

[[ -d "$steam_apps" ]] || exit 0

fix_runtime_permissions() {
    local runtime_dir="$1"
    local mtree="$runtime_dir/mtree.txt.gz"
    [[ -f "$mtree" ]] || return 0
    python3 - "$runtime_dir" "$mtree" <<'PYEOF'
import gzip, re, os, sys
runtime_dir, mtree_path = sys.argv[1], sys.argv[2]
with gzip.open(mtree_path, 'rt', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if not parts or parts[0] in ('/set', '..'):
            continue
        rel = parts[0].lstrip('./')
        if not rel:
            continue
        m = re.search(r'\bmode=(\d+)\b', line)
        if not m:
            continue
        full = os.path.join(runtime_dir, rel)
        try:
            os.chmod(full, int(m.group(1), 8))
        except OSError:
            pass
PYEOF
}

fix_proton_permissions() {
    local proton_dir="$1"
    python3 - "$proton_dir" <<'PYEOF'
import os, sys
def needs_exec(path):
    try:
        with open(path, 'rb') as f:
            h = f.read(4)
        return h[:4] == b'\x7fELF' or h[:2] == b'#!'
    except OSError:
        return False
for dirpath, _, files in os.walk(sys.argv[1]):
    for fname in files:
        full = os.path.join(dirpath, fname)
        try:
            st = os.stat(full)
            if not (st.st_mode & 0o111) and needs_exec(full):
                os.chmod(full, st.st_mode | 0o111)
        except OSError:
            pass
PYEOF
}

fix_prefix() {
    local pfx="$1/pfx"
    [[ -d "$pfx" ]] || return 0

    python3 - "$pfx" <<'PYEOF'
import os, sys
pfx = sys.argv[1]
removed = 0
for dirpath, dirs, files in os.walk(pfx):
    for name in dirs + files:
        full = os.path.join(dirpath, name)
        if os.path.islink(full):
            target = os.readlink(full)
            if 'reparse' in target or 'unsupported' in target:
                os.unlink(full)
                removed += 1
if removed:
    print(f"  removed {removed} broken reparse symlinks")
PYEOF

    local dosdevices="$pfx/dosdevices"
    if [[ -d "$dosdevices" ]]; then
        local c_link="$dosdevices/c:"
        if ! [[ -L "$c_link" ]] || [[ "$(readlink "$c_link")" != "../drive_c" ]]; then
            rm -f "$c_link"
            ln -s ../drive_c "$c_link"
        fi

        local z_link="$dosdevices/z:"
        if ! [[ -L "$z_link" ]] || [[ "$(readlink "$z_link")" != "/" ]]; then
            rm -f "$z_link"
            ln -s / "$z_link"
        fi
    fi

    local bad_steam="C:\\\\windows\\\\system32\\\\unknown\\\\Steam"
    local good_steam="C:\\\\Program Files (x86)\\\\Steam"
    for reg in "$pfx/system.reg" "$pfx/user.reg" "$pfx/userdef.reg"; do
        [[ -f "$reg" ]] || continue
        if grep -q "$bad_steam" "$reg" 2>/dev/null; then
            sed -i "s|$bad_steam|$good_steam|g" "$reg"
            echo "  fixed Steam registry paths in $(basename "$reg")"
        fi
    done
}

migrate_prefix() {
    local src="${1%/}"
    local appid
    appid=$(basename "$src")
    local dst="$steam_apps/compatdata/$appid"

    if [[ -e "$dst" && ! -L "$dst" ]]; then
        fix_prefix "$dst"
        return 0
    fi

    printf "  migrating prefix %s... " "$appid"
    mkdir -p "$steam_apps/compatdata"
    cp -a "$src" "$dst"
    chown -R "$real_uid:$real_gid" "$dst"
    command -v restorecon &>/dev/null && restorecon -Rv "$dst" &>/dev/null || true
    rm -rf "$src" || true
    ln -sf "$dst" "$src" || true
    fix_prefix "$dst"
    echo "done"
}

fix_ntfs_compat() {
    local ntfs_mounts=()
    while IFS= read -r mp; do
        ntfs_mounts+=("$mp")
    done < <(findmnt -rn -o TARGET -t ntfs,ntfs3,fuseblk 2>/dev/null)

    for mp in "${ntfs_mounts[@]}"; do
        local compat="$mp/steamapps/compatdata"
        [[ -d "$compat" ]] || continue
        for prefix in "$compat"/*/; do
            [[ -d "$prefix" && ! -L "$prefix" ]] || continue
            migrate_prefix "$prefix"
        done
    done
}

echo "fixing SteamLinuxRuntime permissions..."
for runtime in "$steam_apps/common/SteamLinuxRuntime_"*/; do
    [[ -d "$runtime" ]] || continue
    printf "  %s... " "$(basename "$runtime")"
    fix_runtime_permissions "$runtime"
    echo "done"
done

echo "fixing Proton permissions..."
for proton in "$steam_apps/common/Proton"*/; do
    [[ -d "$proton" ]] || continue
    printf "  %s... " "$(basename "$proton")"
    fix_proton_permissions "$proton"
    echo "done"
done

echo "migrating NTFS Wine prefixes..."
fix_ntfs_compat

echo "fixing dosdevices in local prefixes..."
if [[ -d "$steam_apps/compatdata" ]]; then
    for prefix in "$steam_apps/compatdata"/*/; do
        [[ -d "$prefix" ]] || continue
        fix_prefix "${prefix%/}"
    done
fi

echo "done"
