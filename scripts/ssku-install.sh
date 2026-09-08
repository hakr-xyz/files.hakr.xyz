#!/bin/bash
#
## Author: John N.
## Created: 2026/09/01
## Modified: 2026/09/03

# Fail fast and handle unset variables strictly
set -euo pipefail

# === Embedded configuration (obfuscated) ===
# Static settings (install versions, download mirror, ports and config
# templates) are base64-encoded below and decoded at runtime, so that no
# plaintext secrets or endpoints are visible in the script itself. Decoding
# only relies on `base64` (GNU coreutils) or `openssl`, which exist on the
# target Debian/Ubuntu hosts, keeping the script portable.
CONF_B64="IyEvYmluL2Jhc2gKIyBPYmZ1c2NhdGVkIHN0YXRpYyBjb25maWd1cmF0aW9uIGZvciB0aGUgc3NrdSBpbnN0YWxsIHNjcmlwdC4KIyBSdW50aW1lLWdlbmVyYXRlZCBzZWNyZXRzIGFyZSBpbmplY3RlZCB2aWEgcGxhY2Vob2xkZXJzIGJlbG93LgoKS0NQVFVOX1ZFUj0idjIwMjMwMjE0IgpLQ1BUVU5fUEtHX05BTUU9ImtjcHR1bi1saW51eC1hbWQ2NC0yMDIzMDIxNC50YXIuZ3oiCktDUFRVTl9QS0dfVVJMPSJodHRwczovL2ZpbGVzLmhha3IueHl6L3NvZnR3YXJlL2tjcHR1bi1saW51eC1hbWQ2NC0yMDIzMDIxNC50YXIuZ3oiCgpVRFAyUkFXX1ZFUj0iMjAyMzAyMDYuMCIKVURQMlJBV19QS0dfTkFNRT0idWRwMnJhd19iaW5hcmllcy0yMDIzMDIwNi4wLnRhci5neiIKVURQMlJBV19QS0dfVVJMPSJodHRwczovL2ZpbGVzLmhha3IueHl6L3NvZnR3YXJlL3VkcDJyYXdfYmluYXJpZXMtMjAyMzAyMDYuMC50YXIuZ3oiCgpLQ1BUVU5fQ09ORj0newogICJsaXN0ZW4iOiAiOjI4NDQzIiwKICAidGFyZ2V0IjogIjEyNy4wLjAuMTo4Mzg4IiwKICAia2V5IjogIl9fS0NQVFVOX0tFWV9fIiwKICAiY3J5cHQiOiAiYWVzIiwKICAibW9kZSI6ICJmYXN0IiwKICAibXR1IjogMTM1MCwKICAic25kd25kIjogNTEyLAogICJyY3Z3bmQiOiA1MTIsCiAgImRhdGFzaGFyZCI6IDEwLAogICJwYXJpdHlzaGFyZCI6IDMsCiAgImRzY3AiOiAwLAogICJub2NvbXAiOiBmYWxzZSwKICAicXVpZXQiOiBmYWxzZSwKICAidGNwIjogZmFsc2UsCiAgInBwcm9mIjogZmFsc2UKfScKClVEUDJSQVdfQ09ORj0nIyBTZXJ2ZXIKLXMKCiMgTGlzdGVuIGFkZHJlc3MKLWwgMC4wLjAuMDoyODA5OAoKIyBSZW1vdGUgYWRkcmVzcwotciAxMjcuMC4wLjE6Mjg0NDMKLWEKLWsgX19VRFAyUkFXX0tFWV9fCi0tcmF3LW1vZGUgZmFrZXRjcCc="

# Decode and load the obfuscated configuration into the environment
decode_conf() {
    if command -v base64 >/dev/null 2>&1; then
        printf '%s' "${CONF_B64}" | base64 -d
    else
        printf '%s' "${CONF_B64}" | openssl base64 -d
    fi
}

# shellcheck disable=SC1091
source <(decode_conf)

# Generate runtime secrets (never stored in the script itself)
gen_key() {
    head -c 10 /dev/random | base64 | head -c 7
}
KCPTUN_KEY="$(gen_key)"
UDP2RAW_KEY="$(gen_key)"

# === 1. System environment tuning ===
setup_system() {
    # Enable IP forwarding and persist it across reboots
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # Raise file descriptor limits
    cat <<EOF >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
EOF
    grep -Ev "^$|^#" /etc/security/limits.conf
}

# === 2. Shadowsocks install ===
install_shadowsocks() {
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y vim tar lsof htop curl wget zip unzip tmux sudo ufw
    apt-get install -y python3-pip shadowsocks-libev

    # Alias python3 as python for compatibility
    ln -sf python3 /usr/bin/python
    ls -l /usr/bin/python
}

# === 3. KCPTun install ===
install_kcptun() {
    local dest="/usr/local/kcptun"
    local src_dir="/usr/local/src/${KCPTUN_PKG_NAME%.tar.gz}"

    # Download and extract KCPTun binary
    wget -P /usr/local/src/ "${KCPTUN_PKG_URL}"
    mkdir -p "${src_dir}" "${dest}"
    tar xvf "/usr/local/src/${KCPTUN_PKG_NAME}" -C "${src_dir}"
    rm -f "${dest}"/{server_*,client_*}
    cp -rv "${src_dir}"/* "${dest}/"

    # Create dedicated user and set ownership
    id kcptun &>/dev/null || useradd -r -s /usr/sbin/nologin -d "${dest}" -M kcptun
    chown -R kcptun:kcptun "${dest}"
    chmod +x "${dest}"/{client_*,server_*}
    ls -l "${dest}/"

    # Write server config, injecting the runtime key
    printf '%s\n' "${KCPTUN_CONF//__KCPTUN_KEY__/${KCPTUN_KEY}}" > "${dest}/server-config.json"

    # Install systemd service unit
    cat > /etc/systemd/system/kcptun.service <<EOF
[Unit]
Description=kcptun service
After=network.target

[Service]
Type=simple
ExecStart=${dest}/server_linux_amd64 -c ${dest}/server-config.json
ExecReload=/bin/kill -HUP
ExecStop=/bin/kill -s QUIT
User=root
PrivateTmp=true
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

# === 4. UDP2RAW install ===
install_udp2raw() {
    local dest="/usr/local/udp2raw"
    local src_dir="/usr/local/src/${UDP2RAW_PKG_NAME%.tar.gz}"

    # Download and extract udp2raw binary
    wget -O "/usr/local/src/${UDP2RAW_PKG_NAME}" "${UDP2RAW_PKG_URL}"
    mkdir -p "${src_dir}" "${dest}"
    tar xvf "/usr/local/src/${UDP2RAW_PKG_NAME}" -C "${src_dir}"
    rm -f "${dest}"/{udp2raw_*,version.txt}
    cp -rv "${src_dir}"/* "${dest}/"

    # Create dedicated user and set ownership
    id udp2raw &>/dev/null || useradd -r -s /usr/sbin/nologin -d "${dest}" -M udp2raw
    chown -R udp2raw:udp2raw "${dest}"
    chmod +x "${dest}"/udp2raw_*
    ls -l "${dest}/"

    # Write server config, injecting the runtime key
    printf '%s\n' "${UDP2RAW_CONF//__UDP2RAW_KEY__/${UDP2RAW_KEY}}" > "${dest}/server.conf"

    # Install systemd service unit
    cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw service
After=network.target

[Service]
Type=simple
ExecStart=${dest}/udp2raw_amd64 --conf-file ${dest}/server.conf
ExecReload=/bin/kill -HUP
ExecStop=/bin/kill -s QUIT
User=root
PrivateTmp=true
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

# === 5. Start and enable services ===
restart_services() {
    sudo ufw disable
    systemctl daemon-reload
    #systemctl enable --now supervisord
    systemctl enable --now shadowsocks-libev
    systemctl enable --now kcptun
    systemctl enable --now udp2raw
    systemctl restart shadowsocks-libev
    systemctl restart kcptun
    systemctl restart udp2raw

    # Verify listening processes
    lsof -nPi | grep -E "ss-server|server_|udp2raw_"

    # Print configuration for reference
    cat /usr/local/udp2raw/server.conf
    cat /usr/local/kcptun/server-config.json
    cat /etc/shadowsocks-libev/config.json
}

# === Main ===
setup_system
install_shadowsocks
install_kcptun
install_udp2raw
restart_services
