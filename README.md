# niri-debian

Build scripts for creating a `.deb` package of [niri](https://github.com/niri-wm/niri) (scrollable-tiling Wayland compositor) and [xwayland-satellite](https://github.com/Supreeeme/xwayland-satellite) for Debian 13 (Trixie).

## Structure

```
.
├── Dockerfile.build    # Docker image for building (Debian Trixie + Rust 1.85+)
├── build-niri.sh       # Build script - creates .deb in deb-output/
└── deb-output/         # Generated .deb packages (gitignored)
```

## Requirements

- Docker
- Debian 13 (Trixie) host or CI runner
- `dpkg-deb` (for packaging)

## Building

```bash
# Default versions (pinned in script)
./build-niri.sh

# Custom versions
NIRI_VERSION=v26.05 XWAYLAND_SATELLITE_VERSION=v0.8.3 ./build-niri.sh
```

The script:
1. Creates a Docker volume for Cargo cache (persists between builds)
2. Builds Docker image with all build dependencies
3. Compiles niri and xwayland-satellite from pinned git tags
4. Creates `.deb` with runtime dependencies and systemd user units
5. Outputs to `deb-output/niri_<version>-1_amd64.deb`

## Runtime Dependencies (auto-installed by apt)

```
dbus-user-session, fuzzel, gnome-keyring, libdisplay-info2, libseat1,
mako-notifier, mate-polkit, pipewire, polkitd, swaybg, swaylock,
waybar, wireplumber, wl-clipboard, xdg-desktop-portal,
xdg-desktop-portal-gtk, xwayland
```

## Versioning

- `niri_version` and `xwayland_satellite_version` in `build-niri.sh` track upstream git tags
- Debian package version: `<niri_version_without_v>-1` (e.g., `v26.04` → `26.04-1`)

## CI/CD

For automated releases, use GitHub Actions:
1. Run `build-niri.sh` on schedule or tag push
2. Upload `deb-output/*.deb` to GitHub Releases

## Notes

- Built on Debian Trixie for glibc compatibility with Trixie targets
- Binaries installed to `/usr/local/bin/`
- Systemd user units installed to `/etc/systemd/user/`
- Wayland desktop entry installed to `/usr/local/share/wayland-sessions/`
- xdg-desktop-portal config for GTK backend
