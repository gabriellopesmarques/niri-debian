#!/bin/bash

set -Eeuo pipefail

# Build niri .deb package in Docker container (Debian Trixie)
# Usage: ./build-niri.sh
#        NIRI_VERSION=v26.05 XWAYLAND_SATELLITE_VERSION=v0.8.3 ./build-niri.sh

niri_version="${NIRI_VERSION:-v26.04}"
xwayland_satellite_version="${XWAYLAND_SATELLITE_VERSION:-v0.8.2}"
cargo_volume="niri-cargo-cache"
deb_version="${niri_version#v}-1"
arch="amd64"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

need_command docker
need_command dpkg-deb

log "Building Niri ${niri_version} and xwayland-satellite ${xwayland_satellite_version} in Docker container (Debian Trixie)"

# Create named volume for Cargo cache
if ! docker volume inspect "$cargo_volume" >/dev/null 2>&1; then
    log "Creating Docker volume '$cargo_volume' for Cargo cache"
    docker volume create "$cargo_volume" >/dev/null
fi

# Build the Docker image
log "Building Docker image"
docker build \
    --build-arg NIRI_VERSION="${niri_version}" \
    --build-arg XWAYLAND_SATELLITE_VERSION="${xwayland_satellite_version}" \
    -t niri-builder \
    -f "$(dirname "$0")/Dockerfile.build" \
    "$(dirname "$0")"

# Run the container with Cargo cache volume mounted
log 'Running build container (this can take a while)'
container_id=$(docker run -d \
    -v "${cargo_volume}:/root/.cargo" \
    niri-builder)

# Wait for container to finish and check exit code
if ! docker wait "$container_id" | grep -q '^0$'; then
    docker logs "$container_id"
    docker rm "$container_id"
    fail 'Docker build failed. Check logs above.'
fi

# Copy artifacts from container to a temporary directory on host
log 'Copying built artifacts from container'
tmp_dir=$(mktemp -d -t niri-build-XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

docker cp "${container_id}:/out/niri" "${tmp_dir}/niri"
docker cp "${container_id}:/out/niri-session" "${tmp_dir}/niri-session"
docker cp "${container_id}:/out/niri.service" "${tmp_dir}/niri.service"
docker cp "${container_id}:/out/niri-shutdown.target" "${tmp_dir}/niri-shutdown.target"
docker cp "${container_id}:/out/niri.desktop" "${tmp_dir}/niri.desktop"
docker cp "${container_id}:/out/xwayland-satellite" "${tmp_dir}/xwayland-satellite"

# Clean up container
docker rm "$container_id"

# Verify artifacts exist
[[ -x "${tmp_dir}/niri" ]] || fail 'Niri binary not found after docker cp.'
[[ -f "${tmp_dir}/niri-session" ]] || fail 'niri-session not found after docker cp.'
[[ -f "${tmp_dir}/niri.service" ]] || fail 'niri.service not found after docker cp.'
[[ -f "${tmp_dir}/niri-shutdown.target" ]] || fail 'niri-shutdown.target not found after docker cp.'
[[ -f "${tmp_dir}/niri.desktop" ]] || fail 'niri.desktop not found after docker cp.'
[[ -x "${tmp_dir}/xwayland-satellite" ]] || fail 'xwayland-satellite binary not found after docker cp.'

log "Creating .deb package structure"

# Create package directory structure
pkg_dir="${tmp_dir}/niri_${deb_version}_${arch}"
mkdir -p "${pkg_dir}/DEBIAN"
mkdir -p "${pkg_dir}/usr/local/bin"
mkdir -p "${pkg_dir}/etc/systemd/user"
mkdir -p "${pkg_dir}/usr/local/share/wayland-sessions"
mkdir -p "${pkg_dir}/usr/local/share/xdg-desktop-portal"

# Copy binaries
install -D -m 0755 "${tmp_dir}/niri" "${pkg_dir}/usr/local/bin/niri"
install -D -m 0755 "${tmp_dir}/niri-session" "${pkg_dir}/usr/local/bin/niri-session"
install -D -m 0755 "${tmp_dir}/xwayland-satellite" "${pkg_dir}/usr/local/bin/xwayland-satellite"

# Copy systemd units
install -D -m 0644 "${tmp_dir}/niri.service" "${pkg_dir}/etc/systemd/user/niri.service"
install -D -m 0644 "${tmp_dir}/niri-shutdown.target" "${pkg_dir}/etc/systemd/user/niri-shutdown.target"

# Copy desktop file
install -D -m 0644 "${tmp_dir}/niri.desktop" "${pkg_dir}/usr/local/share/wayland-sessions/niri.desktop"

# Create portal config
cat > "${pkg_dir}/usr/local/share/xdg-desktop-portal/niri-portals.conf" <<'PORTALS_CONF'
[preferred]
default=gtk;
org.freedesktop.impl.portal.Access=gtk;
org.freedesktop.impl.portal.Notification=gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
PORTALS_CONF

# Create control file
cat > "${pkg_dir}/DEBIAN/control" <<CONTROL
Package: niri
Version: ${deb_version}
Section: x11
Priority: optional
Architecture: ${arch}
Maintainer: Gabriel <gabriel@local>
Depends: dbus-user-session, fuzzel, gnome-keyring, libdisplay-info2, libseat1, mako-notifier, mate-polkit, pipewire, polkitd, swaybg, swaylock, waybar, wireplumber, wl-clipboard, xdg-desktop-portal, xdg-desktop-portal-gtk, xwayland
Description: Niri - A scrollable-tiling Wayland compositor
 Niri is a scrollable-tiling Wayland compositor inspired by
 PaperWM, with a focus on keyboard-driven workflows.
 .
 This package includes niri, niri-session, and xwayland-satellite.
CONTROL

# Create postinst script
cat > "${pkg_dir}/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e

# Refresh systemd user units
systemctl --user daemon-reload || true

echo "Niri installed successfully."
echo "To start a session, log out to a TTY and run: niri-session"
POSTINST
chmod 755 "${pkg_dir}/DEBIAN/postinst"

# Create prerm script
cat > "${pkg_dir}/DEBIAN/prerm" <<'PRERM'
#!/bin/bash
set -e

# Stop and disable user service if running
systemctl --user stop niri.service 2>/dev/null || true
systemctl --user disable niri.service 2>/dev/null || true
systemctl --user daemon-reload || true
PRERM
chmod 755 "${pkg_dir}/DEBIAN/prerm"

# Build the .deb
output_dir="$(dirname "$0")/deb-output"
mkdir -p "${output_dir}"
deb_file="${output_dir}/niri_${deb_version}_${arch}.deb"

log "Building .deb package: ${deb_file}"
dpkg-deb --build --root-owner-group "${pkg_dir}" "${deb_file}"

log "Package created: ${deb_file}"
log "To install on target machine:"
log "  sudo apt install ./${deb_file}"
log ""
log "Runtime dependencies (will be auto-installed by apt):"
log "  dbus-user-session fuzzel gnome-keyring libdisplay-info2 libseat1"
log "  mako-notifier mate-polkit pipewire polkitd swaybg swaylock waybar"
log "  wireplumber wl-clipboard xdg-desktop-portal xdg-desktop-portal-gtk xwayland"

# Update version references in install.sh (in ~/.aliases/niri) - use absolute path
abs_deb_file="$(realpath "${deb_file}")"
sed -i "s|^deb_file=.*|deb_file=\"${abs_deb_file}\"|" "${HOME}/.aliases/niri/install.sh"

log "Updated install.sh to reference new package"

# Cleanup prompt
printf '\n'
read -p "Remove Docker image 'niri-builder' and Cargo cache volume ('$cargo_volume')? [y/N] " -n 1 -r
printf '\n'
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log 'Removing Docker image niri-builder...'
    docker rmi niri-builder 2>/dev/null || true
    log 'Removing Cargo cache volume...'
    docker volume rm "$cargo_volume" 2>/dev/null || true
    log 'Cleanup complete.'
else
    log 'Image and volume kept.'
fi