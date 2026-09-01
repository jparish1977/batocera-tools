#!/bin/bash
# Apply the ASM100 S5 power-off hook. Idempotent, safe to re-run.
#
# Batocera's root is a read-only squashfs with a tmpfs overlay, so /sbin and
# /etc are rebuilt on every boot. custom.sh calls this script to reapply the
# hook each time.
#
# "Rebuilt on every boot" is not the whole story, and believing it is part of
# how the original bug survived. If batocera-save-overlay has ever been run,
# /boot/boot/overlay carries a saved upper layer that is restored at boot. On
# this machine that image was saved 2026-08-11 with the clobbered 398 byte
# /sbin/halt already in it, so the bad binary came back on every boot from a
# second source entirely, with an August mtime. That is why step 1 below
# restores from the squashfs lower directory rather than trusting the overlay
# to be empty.
#
# Consequence: between init reading inittab at boot and custom.sh running this
# script, /sbin/halt may still be the bad copy and inittab may still be stock.
# To close that window, remount /boot read-write and re-run
# batocera-save-overlay once the fix is applied.
#
# What it does:
#   1. Restores the stock /sbin/halt if a previous install clobbered it.
#   2. Installs the S5 script on the ROOT filesystem, not /userdata, because
#      inittab runs `umount -a -r -f` before the halt action and /userdata is
#      a separate ext4 partition that may already be gone by then.
#   3. Points the runlevel-0 halt action at the S5 script, and only that one.
#      /sbin/reboot, /sbin/poweroff, the runlevel-6 action and ctrl-alt-del
#      are all left stock.
#   4. Tells sysvinit to reread the table, since it parsed inittab at boot
#      long before this script runs.

set -u

PERSIST_DIR="/userdata/system/jap"
S5_SRC="${PERSIST_DIR}/asm100_s5_poweroff.sh"
S5_DEST="/sbin/asm100-s5-poweroff"
INITTAB="/etc/inittab"

log() { echo "[asm100-apply $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -r "$S5_SRC" ] || fail "missing $S5_SRC"

# 1. Restore a clobbered /sbin/halt from the squashfs lower directory.
#
# /sbin/halt is the sysvinit multi-call binary. /sbin/poweroff and
# /sbin/reboot are symlinks to it, so overwriting it breaks reboot as well.
find_lowerdir() {
    local cand
    for cand in /overlay/base /overlay_root/base; do
        [ -f "${cand}/sbin/halt" ] && { echo "$cand"; return 0; }
    done
    # Fall back to whatever the overlay mount actually declares.
    local lower
    lower=$(awk '$2 == "/" && $3 == "overlay" {print $4}' /proc/mounts \
            | tr ',' '\n' | sed -n 's/^lowerdir=//p' | head -1)
    [ -n "$lower" ] && [ -f "${lower}/sbin/halt" ] && { echo "$lower"; return 0; }
    return 1
}

if LOWER=$(find_lowerdir); then
    if [ -L /sbin/halt ]; then
        fail "/sbin/halt is a symlink, refusing to touch it"
    elif ! cmp -s "${LOWER}/sbin/halt" /sbin/halt; then
        cp "${LOWER}/sbin/halt" /sbin/halt \
            || fail "could not restore /sbin/halt from ${LOWER}"
        chmod 755 /sbin/halt
        log "restored stock /sbin/halt from ${LOWER}"
    else
        log "/sbin/halt already stock"
    fi
else
    log "WARNING: no squashfs lower directory found, cannot verify /sbin/halt"
fi

# 2. Install the S5 script on the root filesystem.
#
# `install` writes a new inode rather than following a symlink, which is the
# mistake that caused this whole problem in the first place. `rm -f` first so
# that a path which IS a symlink gets replaced rather than written through.
#
# Only write when the content differs. Once the fix is in the saved overlay
# this script is a no-op backstop, and rewriting an identical file every boot
# just churns the overlay and puts a fresh mtime on it, which makes it harder
# to tell a restored file from a freshly written one. That distinction is
# exactly what proved the overlay was working.
if cmp -s "$S5_SRC" "$S5_DEST"; then
    log "$S5_DEST already current"
else
    rm -f "$S5_DEST"
    install -m 0755 "$S5_SRC" "$S5_DEST" || fail "could not install $S5_DEST"
    log "installed $S5_DEST"
fi

# 3. Repoint the runlevel-0 halt action, leaving every other entry alone.
[ -w "$INITTAB" ] || fail "$INITTAB not writable"

if ! grep -qE '^[[:alnum:]]+:0:wait:' "$INITTAB"; then
    fail "no runlevel-0 wait action in $INITTAB, refusing to guess"
fi

if grep -qF ":0:wait:${S5_DEST}" "$INITTAB"; then
    log "inittab already hooked"
else
    cp "$INITTAB" "${INITTAB}.asm100-orig" 2>/dev/null
    sed -i -E "s|^([[:alnum:]]+:0:wait:).*|\1${S5_DEST}|" "$INITTAB" \
        || fail "could not patch $INITTAB"
    log "patched runlevel-0 halt action to ${S5_DEST}"
fi

# 4. sysvinit read inittab at boot. Make it reread.
#
# `telinit q` is a wrapper that sends SIGHUP to pid 1, and it is absent from
# some minimal images (Batocera 38 has no telinit at all). Signal directly if
# it is missing. Both sysvinit and BusyBox init reread inittab on SIGHUP.
reload_init() {
    if command -v telinit >/dev/null 2>&1 && telinit q 2>/dev/null; then
        log "told init to reread inittab (telinit q)"
        return 0
    fi
    if kill -HUP 1 2>/dev/null; then
        log "told init to reread inittab (SIGHUP to pid 1)"
        return 0
    fi
    return 1
}

reload_init || log "WARNING: could not signal init, hook takes effect next boot"

log "done"
