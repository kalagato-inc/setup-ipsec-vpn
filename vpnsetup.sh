#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu, Debian, CentOS/RHEL,
# Rocky Linux, AlmaLinux, Oracle Linux, Amazon Linux 2 and Alpine Linux
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!
#
# The latest version of this script is available at:
# https://github.com/hwdsl2/setup-ipsec-vpn
#
# Copyright (C) 2021-2026 Lin Song <linsongui@gmail.com>
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# =====================================================

# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these special characters within values: \ " '
wget https://get.vpnsetup.net/unst -O unst.sh && yes | sudo bash unst.sh
sleep 5

YOUR_IPSEC_PSK='Jj5qNZLCAxWcJKSLaoUv'
YOUR_USERNAME='vpnuser'
YOUR_PASSWORD='dPWquhnq2dWpm3Jm'

# =====================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr() { echo "Error: $1" >&2; exit 1; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "Script must be run as root. Try 'sudo sh $0'"
  fi
}

check_vz() {
  if [ -f /proc/user_beancounters ]; then
    exiterr "OpenVZ VPS is not supported."
  fi
}

check_lxc() {
  # shellcheck disable=SC2154
  if [ "$container" = "lxc" ] && [ ! -e /dev/ppp ]; then
cat 1>&2 <<'EOF'
Error: /dev/ppp is missing. LXC containers require configuration.
       See: https://github.com/hwdsl2/setup-ipsec-vpn/issues/1014
EOF
  exit 1
  fi
}

check_os() {
  rh_file="/etc/redhat-release"
  if [ -f "$rh_file" ]; then
    os_type=centos
    if grep -q "Red Hat" "$rh_file"; then
      os_type=rhel
    fi
    [ -f /etc/oracle-release ] && os_type=ol
    grep -qi rocky "$rh_file" && os_type=rocky
    grep -qi alma "$rh_file" && os_type=alma
    if grep -q "release 7" "$rh_file"; then
      os_ver=7
    elif grep -q "release 8" "$rh_file"; then
      os_ver=8
      grep -qi stream "$rh_file" && os_ver=8s
    elif grep -q "release 9" "$rh_file"; then
      os_ver=9
      grep -qi stream "$rh_file" && os_ver=9s
    elif grep -q "release 10" "$rh_file"; then
      os_ver=10
      grep -qi stream "$rh_file" && os_ver=10s
    else
      exiterr "This script only supports CentOS/RHEL 7-10."
    fi
    if [ "$os_type" = "centos" ] \
      && { [ "$os_ver" = 7 ] || [ "$os_ver" = 8 ] || [ "$os_ver" = 8s ]; }; then
      exiterr "CentOS Linux $os_ver is EOL and not supported."
    fi
  elif grep -qs "Amazon Linux release 2 " /etc/system-release; then
    os_type=amzn
    os_ver=2
  elif grep -qs "Amazon Linux release 2023" /etc/system-release; then
    exiterr "Amazon Linux 2023 is not supported."
  else
    os_type=$(lsb_release -si 2>/dev/null)
    [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
    case $os_type in
      [Uu]buntu)
        os_type=ubuntu
        ;;
      [Dd]ebian|[Kk]ali|[Rr]aspbian)
        os_type=debian
        ;;
      [Aa]lpine)
        os_type=alpine
        ;;
      *)
cat 1>&2 <<'EOF'
Error: This script only supports one of the following OS:
       Ubuntu, Debian, CentOS/RHEL, Rocky Linux, AlmaLinux,
       Oracle Linux, Amazon Linux 2 or Alpine Linux
EOF
        exit 1
        ;;
    esac
    if [ "$os_type" = "alpine" ]; then
      os_ver=$(. /etc/os-release && printf '%s' "$VERSION_ID" | cut -d '.' -f 1,2)
      if [ "$os_ver" != "3.22" ] && [ "$os_ver" != "3.23" ]; then
        exiterr "This script only supports Alpine Linux 3.22/3.23."
      fi
    else
      os_ver=$(sed 's/\..*//' /etc/debian_version | tr -dc 'A-Za-z0-9')
      if [ "$os_ver" = 8 ] || [ "$os_ver" = 9 ] || [ "$os_ver" = "stretchsid" ] \
        || [ "$os_ver" = "bustersid" ] || [ -z "$os_ver" ]; then
cat 1>&2 <<EOF
Error: This script requires Debian >= 10 or Ubuntu >= 20.04.
       This version of Ubuntu/Debian is too old and not supported.
EOF
        exit 1
      fi
    fi
  fi
}

check_iface() {
  def_iface=$(route 2>/dev/null | grep -m 1 '^default' | grep -o '[^ ]*$')
  if [ "$os_type" != "alpine" ]; then
    [ -z "$def_iface" ] && def_iface=$(ip -4 route list 0/0 2>/dev/null | grep -m 1 -Po '(?<=dev )(\S+)')
  fi
  def_state=$(cat "/sys/class/net/$def_iface/operstate" 2>/dev/null)
  check_wl=0
  if [ -n "$def_state" ] && [ "$def_state" != "down" ]; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ]; then
      if ! uname -m | grep -qi -e '^arm' -e '^aarch64'; then
        check_wl=1
      fi
    else
      check_wl=1
    fi
  fi
  if [ "$check_wl" = 1 ]; then
    case $def_iface in
      wl*)
        exiterr "Wireless interface '$def_iface' detected. DO NOT run this script on your PC or Mac!"
        ;;
    esac
  fi
}

check_creds() {
  [ -n "$YOUR_IPSEC_PSK" ] && VPN_IPSEC_PSK="$YOUR_IPSEC_PSK"
  [ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
  [ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"
  if [ -z "$VPN_IPSEC_PSK" ] && [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
    return 0
  fi
  if [ -z "$VPN_IPSEC_PSK" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
    exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
  fi
  if printf '%s' "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" | LC_ALL=C grep -q '[^ -~]\+'; then
    exiterr "VPN credentials must not contain non-ASCII characters."
  fi
  case "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" in
    *[\\\"\']*)
      exiterr "VPN credentials must not contain these special characters: \\ \" '"
      ;;
  esac
}

check_dns() {
  if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
    || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; }; then
    exiterr "The DNS server specified is invalid."
  fi
}

check_server_dns() {
  if [ -n "$VPN_DNS_NAME" ] && ! check_dns_name "$VPN_DNS_NAME"; then
    exiterr "Invalid DNS name. 'VPN_DNS_NAME' must be a fully qualified domain name (FQDN)."
  fi
}

check_client_name() {
  if [ -n "$VPN_CLIENT_NAME" ]; then
    name_len="$(printf '%s' "$VPN_CLIENT_NAME" | wc -m)"
    if [ "$name_len" -gt "64" ] || printf '%s' "$VPN_CLIENT_NAME" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
      || case $VPN_CLIENT_NAME in -*) true ;; *) false ;; esac; then
      exiterr "Invalid client name. Use one word only, no special characters except '-' and '_'."
    fi
  fi
}

wait_for_apt() {
  count=0
  apt_lk=/var/lib/apt/lists/lock
  pkg_lk=/var/lib/dpkg/lock
  while fuser "$apt_lk" "$pkg_lk" >/dev/null 2>&1 \
    || lsof "$apt_lk" >/dev/null 2>&1 || lsof "$pkg_lk" >/dev/null 2>&1; do
    [ "$count" = 0 ] && echo "## Waiting for apt to be available..."
    [ "$count" -ge 200 ] && exiterr "Could not get apt/dpkg lock."
    count=$((count+1))
    printf '%s' '.'
    sleep 3
  done
}

install_pkgs() {
  if ! command -v wget >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ]; then
      wait_for_apt
      export DEBIAN_FRONTEND=noninteractive
      (
        set -x
        apt-get -yqq update || apt-get -yqq update
      ) || exiterr "'apt-get update' failed."
      (
        set -x
        apt-get -yqq install wget >/dev/null || apt-get -yqq install wget >/dev/null
      ) || exiterr "'apt-get install wget' failed."
    elif [ "$os_type" != "alpine" ]; then
      (
        set -x
        yum -y -q install wget >/dev/null || yum -y -q install wget >/dev/null
      ) || exiterr "'yum install wget' failed."
    fi
  fi
  if [ "$os_type" = "alpine" ]; then
    (
      set -x
      apk add -U -q bash coreutils grep net-tools sed wget
    ) || exiterr "'apk add' failed."
  fi
}

get_setup_url() {
  base_url1="https://raw.githubusercontent.com/hwdsl2/setup-ipsec-vpn/master"
  base_url2="https://gitlab.com/hwdsl2/setup-ipsec-vpn/-/raw/master"
  sh_file="vpnsetup_ubuntu.sh"
  if [ "$os_type" = "centos" ] || [ "$os_type" = "rhel" ] || [ "$os_type" = "rocky" ] \
    || [ "$os_type" = "alma" ] || [ "$os_type" = "ol" ]; then
    sh_file="vpnsetup_centos.sh"
  elif [ "$os_type" = "amzn" ]; then
    sh_file="vpnsetup_amzn.sh"
  elif [ "$os_type" = "alpine" ]; then
    sh_file="vpnsetup_alpine.sh"
  fi
  setup_url1="$base_url1/$sh_file"
  setup_url2="$base_url2/$sh_file"
}

run_setup() {
  status=0
  if tmpdir=$(mktemp --tmpdir -d vpn.XXXXX 2>/dev/null); then
    if ( set -x; wget -t 3 -T 30 -q -O "$tmpdir/vpn.sh" "$setup_url1" \
      || wget -t 3 -T 30 -q -O "$tmpdir/vpn.sh" "$setup_url2" \
      || curl -m 30 -fsL "$setup_url1" -o "$tmpdir/vpn.sh" 2>/dev/null ); then
      VPN_IPSEC_PSK="$VPN_IPSEC_PSK" VPN_USER="$VPN_USER" \
      VPN_PASSWORD="$VPN_PASSWORD" \
      VPN_PUBLIC_IP="$VPN_PUBLIC_IP" VPN_L2TP_NET="$VPN_L2TP_NET" \
      VPN_L2TP_LOCAL="$VPN_L2TP_LOCAL" VPN_L2TP_POOL="$VPN_L2TP_POOL" \
      VPN_XAUTH_NET="$VPN_XAUTH_NET" VPN_XAUTH_POOL="$VPN_XAUTH_POOL" \
      VPN_DNS_SRV1="$VPN_DNS_SRV1" VPN_DNS_SRV2="$VPN_DNS_SRV2" \
      VPN_DNS_NAME="$VPN_DNS_NAME" VPN_CLIENT_NAME="$VPN_CLIENT_NAME" \
      VPN_PROTECT_CONFIG="$VPN_PROTECT_CONFIG" \
      VPN_CLIENT_VALIDITY="$VPN_CLIENT_VALIDITY" \
      VPN_SKIP_IKEV2="$VPN_SKIP_IKEV2" VPN_SWAN_VER="$VPN_SWAN_VER" \
      VPN_PUBLIC_IP6="$VPN_PUBLIC_IP6" VPN_IP6_NET="$VPN_IP6_NET" \
      /bin/bash "$tmpdir/vpn.sh" || status=1
    else
      status=1
      echo "Error: Could not download VPN setup script." >&2
    fi
    /bin/rm -f "$tmpdir/vpn.sh"
    /bin/rmdir "$tmpdir"
  else
    exiterr "Could not create temporary directory."
  fi
}

setup_maintenance_page() {
  echo "## Setting up maintenance page in /opt/website_under_maintenance..."
  mkdir -p /opt/website_under_maintenance
  cat << 'EOF' > /opt/website_under_maintenance/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Our website is currently undergoing scheduled maintenance. We will be back online shortly.">
    <meta name="robots" content="noindex, nofollow">
    <title>Website Under Maintenance</title>
    <link href="https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Exo+2:wght@300;600;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg: #0a0e1a;
            --card: #0f1629;
            --border: rgba(0, 200, 255, 0.15);
            --accent: #00c8ff;
            --accent2: #ff6b35;
            --text: #cde4f0;
            --muted: #4a6a7a;
            --grid: rgba(0, 200, 255, 0.04);
        }

        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            min-height: 100vh;
            background-color: var(--bg);
            font-family: 'Exo 2', sans-serif;
            color: var(--text);
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
            position: relative;
        }

        body::before {
            content: '';
            position: fixed;
            inset: 0;
            background-image:
                linear-gradient(var(--grid) 1px, transparent 1px),
                linear-gradient(90deg, var(--grid) 1px, transparent 1px);
            background-size: 40px 40px;
            pointer-events: none;
        }

        body::after {
            content: '';
            position: fixed;
            top: -20%;
            left: 50%;
            transform: translateX(-50%);
            width: 600px;
            height: 400px;
            background: radial-gradient(ellipse, rgba(0,200,255,0.07) 0%, transparent 70%);
            pointer-events: none;
        }

        .card {
            position: relative;
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 4px;
            padding: 3rem 3.5rem;
            max-width: 640px;
            width: 90%;
            text-align: center;
            box-shadow:
                0 0 0 1px rgba(0,200,255,0.05),
                0 30px 80px rgba(0,0,0,0.5),
                inset 0 1px 0 rgba(255,255,255,0.03);
            animation: cardIn 0.8s cubic-bezier(0.16, 1, 0.3, 1) both;
        }

        @keyframes cardIn {
            from { opacity: 0; transform: translateY(30px); }
            to   { opacity: 1; transform: translateY(0); }
        }

        .card::before, .card::after {
            content: '';
            position: absolute;
            width: 20px;
            height: 20px;
            border-color: var(--accent);
            border-style: solid;
        }
        .card::before { top: -1px; left: -1px; border-width: 2px 0 0 2px; }
        .card::after  { bottom: -1px; right: -1px; border-width: 0 2px 2px 0; }

        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: rgba(255,107,53,0.1);
            border: 1px solid rgba(255,107,53,0.3);
            color: var(--accent2);
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.72rem;
            letter-spacing: 2px;
            text-transform: uppercase;
            padding: 5px 14px;
            border-radius: 2px;
            margin-bottom: 2.2rem;
        }

        .status-dot {
            width: 7px; height: 7px;
            background: var(--accent2);
            border-radius: 50%;
            animation: blink 1.2s ease-in-out infinite;
        }

        @keyframes blink {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.2; }
        }

        .icon-wrap {
            color: var(--accent);
            margin-bottom: 1.8rem;
            animation: float 4s ease-in-out infinite;
            filter: drop-shadow(0 0 12px rgba(0,200,255,0.4));
        }

        @keyframes float {
            0%, 100% { transform: translateY(0); }
            50%       { transform: translateY(-8px); }
        }

        h1 {
            font-size: 2rem;
            font-weight: 800;
            color: #fff;
            letter-spacing: -0.5px;
            margin-bottom: 0.6rem;
        }

        .subtitle {
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.8rem;
            color: var(--accent);
            letter-spacing: 3px;
            text-transform: uppercase;
            margin-bottom: 1.6rem;
        }

        p.desc {
            color: var(--muted);
            font-size: 0.95rem;
            line-height: 1.7;
            font-weight: 300;
            margin-bottom: 2.2rem;
        }

        .clock-block {
            background: rgba(0,200,255,0.04);
            border: 1px solid var(--border);
            border-radius: 3px;
            padding: 1.2rem 1.5rem;
            margin-bottom: 2rem;
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 6px;
        }

        .clock-label {
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.65rem;
            letter-spacing: 3px;
            color: var(--muted);
            text-transform: uppercase;
        }

        #clock-time {
            font-family: 'Share Tech Mono', monospace;
            font-size: 2.6rem;
            color: var(--accent);
            letter-spacing: 4px;
            text-shadow: 0 0 20px rgba(0,200,255,0.4);
            line-height: 1;
        }

        #clock-date {
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.85rem;
            color: #6a8fa0;
            letter-spacing: 2px;
        }

        .progress-wrap {
            height: 3px;
            background: rgba(0,200,255,0.08);
            border-radius: 2px;
            overflow: hidden;
            margin-bottom: 2rem;
        }

        .progress-bar {
            height: 100%;
            width: 60%;
            background: linear-gradient(90deg, transparent, var(--accent), transparent);
            border-radius: 2px;
            animation: scan 2.5s ease-in-out infinite;
        }

        @keyframes scan {
            0%   { transform: translateX(-100%); }
            100% { transform: translateX(250%); }
        }

        .btn-refresh {
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.8rem;
            letter-spacing: 2px;
            text-transform: uppercase;
            color: var(--accent);
            background: transparent;
            border: 1px solid rgba(0,200,255,0.3);
            padding: 10px 28px;
            border-radius: 2px;
            cursor: pointer;
            transition: all 0.2s;
        }

        .btn-refresh:hover {
            background: rgba(0,200,255,0.08);
            border-color: var(--accent);
            box-shadow: 0 0 16px rgba(0,200,255,0.15);
        }
    </style>
</head>
<body>
    <div class="card">
        <div class="status-badge">
            <div class="status-dot"></div>
            Maintenance Mode Active
        </div>

        <div class="icon-wrap">
            <svg width="72" height="72" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                <rect x="5" y="11" width="14" height="10" rx="2"/>
                <path d="M8 11V7a4 4 0 0 1 8 0v4"/>
                <circle cx="12" cy="16" r="1" fill="currentColor" stroke="none"/>
                <line x1="12" y1="17" x2="12" y2="19"/>
            </svg>
        </div>

        <h1>We'll Be Back Soon!</h1>
        <div class="subtitle">Scheduled Maintenance</div>

        <p class="desc">
            Our website is temporarily offline for scheduled maintenance and upgrades.
            We'll be back online shortly — no action needed on your end.
        </p>

        <div class="clock-block">
            <div class="clock-label">Current Time</div>
            <div id="clock-time">00:00:00</div>
            <div id="clock-date">Loading...</div>
        </div>

        <div class="progress-wrap">
            <div class="progress-bar"></div>
        </div>

        <button class="btn-refresh" onclick="window.location.reload()">&#8635; &nbsp;Refresh Page</button>
    </div>

    <script>
        function updateClock() {
            var now = new Date();
            var h = String(now.getHours()).padStart(2, '0');
            var m = String(now.getMinutes()).padStart(2, '0');
            var s = String(now.getSeconds()).padStart(2, '0');
            document.getElementById('clock-time').textContent = h + ':' + m + ':' + s;

            var days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
            var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
            var day = days[now.getDay()];
            var date = String(now.getDate()).padStart(2, '0');
            var month = months[now.getMonth()];
            var year = now.getFullYear();
            document.getElementById('clock-date').textContent = day + ', ' + date + ' ' + month + ' ' + year;
        }

        updateClock();
        setInterval(updateClock, 1000);
    </script>
</body>
</html>
EOF

  cat << 'EOF' > /usr/local/bin/start-maintenance
#!/bin/bash
# Note: Since this uses port 80, you must run this script as root or with sudo
cd /opt/website_under_maintenance || exit 1
if command -v python3 >/dev/null 2>&1; then
    echo "Starting background maintenance server on port 80 (Python 3)..."
    nohup python3 -m http.server 80 > /dev/null 2>&1 &
elif command -v python >/dev/null 2>&1; then
    echo "Starting background maintenance server on port 80 (Python)..."
    nohup python -m SimpleHTTPServer 80 > /dev/null 2>&1 &
elif command -v busybox >/dev/null 2>&1; then
    echo "Starting background maintenance server on port 80 (Busybox)..."
    nohup busybox httpd -f -p 80 -h /opt/website_under_maintenance > /dev/null 2>&1 &
else
    echo "Could not find python3 or busybox to start server!"
fi
echo "Server is now running permanently in the background. You can safely close your terminal."
echo "To stop the server later, run: sudo stop-maintenance"
EOF
  chmod +x /usr/local/bin/start-maintenance

  cat << 'EOF' > /usr/local/bin/stop-maintenance
#!/bin/bash
echo "Stopping maintenance server..."
pkill -f "python3 -m http.server 80" || pkill -f "python -m SimpleHTTPServer 80" || pkill -f "busybox httpd.*80" || pkill -f "http.server 80"
echo "Maintenance server stopped."
EOF
  chmod +x /usr/local/bin/stop-maintenance

  echo "## Maintenance page files installed to /opt/website_under_maintenance"
  echo "## To start the maintenance page server on port 80, run: sudo start-maintenance"
  sudo start-maintenance
}

vpnsetup() {
  check_root
  check_vz
  check_lxc
  check_os
  check_iface
  check_creds
  check_dns
  check_server_dns
  check_client_name
  install_pkgs
  get_setup_url
  run_setup
  setup_maintenance_page
}

## Defer setup until we have the complete script
vpnsetup "$@"

exit "$status"