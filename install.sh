#!/usr/bin/env bash
# Qalqon agentini o'rnatish — Ubuntu/Debian va Rocky/RHEL uchun.
#
# BU FAYL AVTOMATIK YARATILADI (Qalqon ombori: deploy/publish-agent.sh).
# Qo'lda tahrirlamang — o'zgarishlar asl skriptga kiritiladi.
#
# Ishlatish:
#   curl -fsSL https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/install.sh \
#     | sudo bash -s -- --server https://SERVER --token <TOKEN>
#
# Ichki CA (o'z sertifikatingiz) bo'lsa:
#     ... --ca-cert https://SERVER/static/ca.crt     (fayl yoki URL)
#
# Binar sukut bo'yicha shu ombordan olinadi; boshqa manba uchun:
#     ... --binary-base https://SERVER/static
set -euo pipefail

SERVER=""
TOKEN=""
INSECURE=""
CA_CERT=""
BINARY_BASE="${QALQON_BINARY_BASE:-https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/bin}"
BIN_PATH="/usr/local/bin/qalqon-agent"
UNIT_PATH="/etc/systemd/system/qalqon-agent.service"
CA_DEST="/etc/ssl/certs/qalqon-ca.crt"

die() { printf '\033[31mxato:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ✓\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)   SERVER="${2:?--server uchun qiymat kerak}"; shift 2 ;;
    --token)    TOKEN="${2:?--token uchun qiymat kerak}"; shift 2 ;;
    --insecure) INSECURE="--insecure"; shift ;;
    --ca-cert)  CA_CERT="${2:?--ca-cert uchun qiymat kerak}"; shift 2 ;;
    --binary-base) BINARY_BASE="${2:?--binary-base uchun qiymat kerak}"; shift 2 ;;
    --bin)      BIN_PATH="${2:?--bin uchun qiymat kerak}"; shift 2 ;;
    -h|--help)
      # Birinchi izoh blokini chiqaramiz (qator raqamiga bog'lanmaydi)
      sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
    *) die "noma'lum argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "root huquqi kerak (sudo bilan ishga tushiring)"
[[ -n "$SERVER" ]] || die "--server majburiy"
SERVER="${SERVER%/}"
[[ -n "$TOKEN" ]] || die "--token majburiy"

# --- OS va arxitekturani aniqlash ---
# Diqqat: ${var:-word} ichida apostrof bash parserini buzadi, shuning uchun
# qiymatni ikki qadamda olamiz.
OS_ID="unknown"
if [[ -r /etc/os-release ]]; then
  OS_ID="$(. /etc/os-release; printf '%s' "$ID")"
  [[ -n "$OS_ID" ]] || OS_ID="unknown"
fi

# Nomlar agent/targets.txt bilan bir xil bo'lishi shart.
case "$(uname -m)" in
  x86_64|amd64)       ARCH="amd64" ;;
  aarch64|arm64)      ARCH="arm64" ;;
  armv7l|armv7|armv6l) ARCH="armv7" ;;
  i386|i486|i586|i686) ARCH="386" ;;
  riscv64)            ARCH="riscv64" ;;
  *) die "qo'llab-quvvatlanmaydigan arxitektura: $(uname -m)" ;;
esac

case "$OS_ID" in
  ubuntu|debian|rocky|rhel|centos|almalinux|fedora) ;;
  *) info "OGOHLANTIRISH: '$OS_ID' sinovdan o'tmagan (Ubuntu va Rocky qo'llab-quvvatlanadi)" ;;
esac

info "Host: $(hostname) — $OS_ID / $ARCH"

command -v curl >/dev/null 2>&1 || die "curl o'rnatilmagan"
command -v systemctl >/dev/null 2>&1 || die "systemd topilmadi"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CURL_OPTS=(-fsSL --retry 3 --retry-delay 2 --max-time 180)
[[ -n "$INSECURE" ]] && CURL_OPTS+=(-k)

# --- CA sertifikati (ichki CA bo'lsa) ---
# Diqqat: CA ni o'rnatishni binarni yuklashdan OLDIN bajaramiz, chunki
# binar ham o'sha ishonchsiz serverdan kelishi mumkin.
if [[ -n "$CA_CERT" ]]; then
  case "$CA_CERT" in
    http://*|https://*)
      # CA ni olishda -k ishlatamiz: hali ishonch zanjiri yo'q. Keyin
      # sha256 ni foydalanuvchi o'zi solishtirishi uchun chop etamiz.
      curl -fsSL -k --retry 3 --max-time 60 -o "$TMP/ca.crt" "$CA_CERT" \
        || die "CA yuklab olinmadi: $CA_CERT"
      ;;
    *)
      [[ -r "$CA_CERT" ]] || die "CA fayli o'qilmadi: $CA_CERT"
      cp "$CA_CERT" "$TMP/ca.crt"
      ;;
  esac
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$TMP/ca.crt" -noout >/dev/null 2>&1 \
      || die "CA fayli yaroqli X.509 sertifikat emas: $CA_CERT"
  else
    # openssl yo'q bo'lsa hech bo'lmasa PEM sarlavhasini tekshiramiz
    grep -q 'BEGIN CERTIFICATE' "$TMP/ca.crt" \
      || die "CA fayli PEM sertifikatga o'xshamaydi: $CA_CERT"
  fi
  install -m 0644 -o root -g root "$TMP/ca.crt" "$CA_DEST"
  ok "CA o'rnatildi: $CA_DEST (sha256 $(sha256sum "$CA_DEST" | cut -c1-16)...)"
fi

# --- Agent binarini yuklab olish ---
# Sukut bo'yicha markaziy serverning static/ papkasidan; --binary-base bilan
# boshqa manbadan (masalan GitHub ombori) olish mumkin.
BASE="${BINARY_BASE:-$SERVER/static}"
BASE="${BASE%/}"

# DIQQAT: `curl --cacert` standart CA ro'yxatini ALMASHTIRADI, unga qo'shmaydi.
# Shuning uchun uni faqat markaziy serverga murojaatda ishlatamiz. Binar GitHub
# kabi ommaviy manbadan kelsa, o'sha yerda tizimning oddiy CA ro'yxati kerak —
# aks holda yuklash "certificate verify failed" bilan yiqiladi.
BIN_OPTS=("${CURL_OPTS[@]}")
if [[ -n "$CA_CERT" && "$BASE" == "$SERVER"* ]]; then
  BIN_OPTS+=(--cacert "$CA_DEST")
fi

info "Agent yuklab olinyapti ($ARCH)..."
# curl ning chiqish kodini aniq ushlaymiz: sabablar butunlay har xil va
# umumiy "yuklab olinmadi" xabari foydalanuvchini noto'g'ri yo'nalishga
# yuboradi (masalan sertifikat muammosida binarni qidirishga).
set +e
curl "${BIN_OPTS[@]}" -o "$TMP/qalqon-agent" "$BASE/qalqon-agent-linux-$ARCH"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  URL="$BASE/qalqon-agent-linux-$ARCH"
  case $rc in
    60|51|77)
      die "server sertifikati bu manzilga mos emas: $URL

    Sertifikat $SERVER uchun yasalmagan (SAN ro'yxatida bu IP/domen yo'q).
    Markaziy serverda tekshiring:
      openssl x509 -in certs/server.crt -noout -ext subjectAltName

    To'g'ri manzil bilan qayta yasang (CA o'zgarmaydi, agentlarga tegish shart emas):
      ./deploy/gen-cert.sh <SHU-MANZIL>
      docker compose --profile tls restart nginx" ;;
    22)
      die "binar topilmadi (HTTP xatosi): $URL

    Markaziy serverda binar bormi:
      curl -kI $BASE/qalqon-agent-linux-$ARCH
    Yo'q bo'lsa:  docker compose up -d --build" ;;
    6|7|28)
      die "manbaga ulanib bo'lmadi: $URL

    Tarmoq yoki firewall to'syapti. Shu serverdan tekshiring:
      curl -kI $SERVER/healthz" ;;
    *)
      die "binar yuklab olinmadi (curl kodi $rc): $URL" ;;
  esac
fi

# Hash tekshiruvi — manba beradigan bo'lsa
if curl "${BIN_OPTS[@]}" -o "$TMP/sha256" \
     "$BASE/qalqon-agent-linux-$ARCH.sha256" 2>/dev/null; then
  EXPECTED="$(awk '{print $1}' "$TMP/sha256")"
  ACTUAL="$(sha256sum "$TMP/qalqon-agent" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "sha256 mos kelmadi — yuklanish buzilgan yoki o'zgartirilgan"
  ok "sha256 tasdiqlandi"
fi

install -m 0755 -o root -g root "$TMP/qalqon-agent" "$BIN_PATH"
ok "$BIN_PATH o'rnatildi ($("$BIN_PATH" version))"

# --- Ro'yxatga olish ---
info "Serverga ro'yxatga olinyapti..."
"$BIN_PATH" enroll --server "$SERVER" --token "$TOKEN" --force \
  ${INSECURE:+--insecure} ${CA_CERT:+--ca-cert "$CA_DEST"}

# --- systemd unit ---
info "systemd servisi sozlanyapti..."
cat > "$UNIT_PATH" <<'UNIT'
[Unit]
Description=Qalqon xavfsizlik agenti
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/qalqon-agent run
Restart=always
RestartSec=15
User=root

NoNewPrivileges=yes
ProtectHome=read-only
ProtectClock=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryHigh=256M
MemoryMax=512M
TasksMax=64

StateDirectory=qalqon
StateDirectoryMode=0750
ReadWritePaths=/var/lib/qalqon -/etc/ufw -/etc/firewalld -/etc/default/ufw

StandardOutput=journal
StandardError=journal
SyslogIdentifier=qalqon-agent

[Install]
WantedBy=multi-user.target
UNIT

# Docker bor bo'lsa, qoidalarni Docker ishga tushgandan keyin darhol tiklash
# uchun qo'shimcha unit. Aks holda reboot dan keyin agentning navbatdagi
# skanigacha (sukut 120s) Docker portlari himoyasiz ochiq turadi.
if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
  cat > /etc/systemd/system/qalqon-docker-fw.service <<'DKUNIT'
[Unit]
Description=Qalqon Docker firewall qoidalarini tiklash
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/qalqon-agent docker-fw reconcile
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=qalqon-docker-fw

[Install]
WantedBy=docker.service
DKUNIT
  ok "Docker aniqlandi — qalqon-docker-fw.service qo'shildi"
fi

systemctl daemon-reload
systemctl enable --now qalqon-agent
ok "qalqon-agent yoqildi"
if [[ -f /etc/systemd/system/qalqon-docker-fw.service ]]; then
  systemctl enable qalqon-docker-fw >/dev/null 2>&1 && ok "qalqon-docker-fw yoqildi"
fi

sleep 3
if systemctl is-active --quiet qalqon-agent; then
  ok "servis ishlayapti"
else
  printf '\033[33m  ! servis ishga tushmadi, loglar:\033[0m\n'
  journalctl -u qalqon-agent -n 20 --no-pager || true
  exit 1
fi

echo
info "Tayyor. Host UI da ko'rinishi uchun 1 daqiqa kutish mumkin: $SERVER/ui/hosts"
echo "  Loglar:  journalctl -u qalqon-agent -f"
echo "  Holat:   qalqon-agent status"
echo "  Tekshir: qalqon-agent check"
