#!/bin/bash
set -e

# find unmounted NTFS partitions via lsblk
mapfile -t lines < <(lsblk -P -o NAME,FSTYPE,UUID,LABEL,MOUNTPOINT 2>/dev/null)

unmounted_uuids=()
unmounted_labels=()
unmounted_points=()

for line in "${lines[@]}"; do
    eval "$(echo "$line" | sed 's/ /\n/g' | grep '=' | sed 's/^/local /')" 2>/dev/null || true

    [[ "$FSTYPE" == "ntfs" || "$FSTYPE" == "ntfs3" ]] || continue
    [[ -z "$MOUNTPOINT" ]] || continue
    [[ -n "$UUID" ]] || continue

    if [[ -n "$LABEL" ]]; then
        mount_name="${LABEL,,}"          # lowercase
        mount_name="${mount_name// /_}"  # spaces to underscores
    else
        mount_name="$NAME"
    fi

    unmounted_uuids+=("$UUID")
    unmounted_labels+=("${LABEL:-$NAME}")
    unmounted_points+=("/mnt/$mount_name")
done

if [[ ${#unmounted_uuids[@]} -eq 0 ]]; then
    echo "all NTFS partitions already mounted"
    exit 0
fi

echo "unmounted NTFS partitions:"
for i in "${!unmounted_uuids[@]}"; do
    echo "  ${unmounted_labels[$i]} -> ${unmounted_points[$i]}"
done

read -r -p "mount them? [y/N] " answer
[[ "${answer,,}" == "y" ]] || exit 0

# determine real user's uid/gid (works under sudo too)
uid="${SUDO_UID:-$(id -u)}"
gid="${SUDO_GID:-$(id -g)}"

for i in "${!unmounted_uuids[@]}"; do
    point="${unmounted_points[$i]}"
    uuid="${unmounted_uuids[$i]}"

    printf "  mounting %s... " "$point"
    mkdir -p "$point"

    if mount -t ntfs3 -o "uid=$uid,gid=$gid,dmask=022,fmask=133" "UUID=$uuid" "$point"; then
        echo "ok"
    else
        echo "failed"
    fi
done
