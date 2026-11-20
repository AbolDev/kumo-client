Name:           kumo
Version:        @VERSION@
Release:        1
Summary:        Free VPN client powered by sing-box and Xray
License:        GPL-3.0-only
URL:            https://github.com/AbolDev/kumo-client
BuildArch:      @RPMARCH@
AutoReqProv:    no
Requires:       gtk3
Recommends:     libayatana-appindicator-gtk3

%global debug_package %{nil}
%global __strip /bin/true
%global _build_id_links none
%define __os_install_post %{nil}

%description
Kumo connects to the servers and subscriptions you choose. It can run as a local
proxy (also set as the system proxy) or tunnel the whole computer.

%install
mkdir -p %{buildroot}/opt/kumo
cp -a %{_sourcedir}/bundle/. %{buildroot}/opt/kumo/
install -Dm644 %{_sourcedir}/kumo.desktop %{buildroot}/usr/share/applications/kumo.desktop
install -Dm644 %{_sourcedir}/kumo.png %{buildroot}/usr/share/pixmaps/kumo.png

%post
# The tunnel needs network privileges. They go to the VPN core for the members of the group "kumo"
# only, not for every program and user of the computer; everybody else is asked for a password.
if command -v setcap >/dev/null 2>&1; then
  getent group kumo >/dev/null 2>&1 || groupadd --system kumo >/dev/null 2>&1 || true
  chgrp kumo /opt/kumo/kumo-core >/dev/null 2>&1 || true
  chmod 750 /opt/kumo/kumo-core >/dev/null 2>&1 || true
  setcap cap_net_admin,cap_net_bind_service,cap_net_raw+ep /opt/kumo/kumo-core || true
  # the person who installed it (with sudo, pkexec, or the one signed in at the console) is in the
  # group from the next sign-in; anybody else is told by the app how to join it
  who="${SUDO_USER:-}"
  if [ -z "$who" ] && [ -n "${PKEXEC_UID:-}" ]; then who="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"; fi
  if [ -z "$who" ]; then who="$(logname 2>/dev/null || true)"; fi
  if [ -n "$who" ] && [ "$who" != root ]; then
    usermod -aG kumo "$who" >/dev/null 2>&1 || true
  fi
fi
exit 0

%files
/opt/kumo
/usr/share/applications/kumo.desktop
/usr/share/pixmaps/kumo.png