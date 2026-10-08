# Qalqon Agent — tayyor binarlar

Bu ombor [Qalqon](https://github.com/shahz0dbek/Qalqon) platformasining
**oldindan qurilgan agent binarlarini** saqlaydi.

Agentni o'rnatish uchun serverda Go, kompilyator yoki boshqa hech narsa
kerak emas — binar statik (CGO yo'q), hech qanday kutubxonaga bog'lanmagan.

Joriy versiya: **0.1.0**

---

## Tez o'rnatish

```bash
curl -fsSL https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/install.sh \
  | sudo bash -s -- --server https://MARKAZIY-SERVER --token <TOKEN>
```

Skript o'zi: arxitekturani aniqlaydi → mos binarni yuklaydi → sha256 ni
tekshiradi → `/usr/local/bin/qalqon-agent` ga o'rnatadi → serverga ro'yxatdan
o'tkazadi → systemd servisini yoqadi. Docker bor bo'lsa `qalqon-docker-fw`
servisini ham qo'shadi.

Token markaziy serverda olinadi:

```bash
docker compose exec server python3 manage.py token --label "yangi-server" --max-uses 5
```

### Ichki tarmoq / o'z sertifikatingiz bo'lsa

Let's Encrypt ichki IP ga sertifikat bermaydi, shuning uchun LAN da o'z CA'ngiz
ishlatiladi. CA ni skriptga bering (fayl yo'li yoki URL):

```bash
curl -fsSLk https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/install.sh \
  | sudo bash -s -- --server https://192.168.1.50 --token <TOKEN> \
      --ca-cert https://192.168.1.50/static/ca.crt
```

CA `/etc/ssl/certs/qalqon-ca.crt` ga o'rnatiladi va agent faqat shu CA ga
ishonadi. `--insecure` ham bor, lekin u sertifikatni umuman tekshirmaydi —
**faqat sinov uchun**.

---

## Qaysi faylni olish kerak

Agent **faqat Linux** uchun. OS muhim emas — bitta statik binar barcha
distributivlarda ishlaydi. Muhimi — protsessor arxitekturasi:

```bash
uname -m     # shu natijaga qarang
```

| `uname -m` | Fayl | Qayerda uchraydi |
|---|---|---|
| `x86_64` | [`qalqon-agent-linux-amd64`](bin/qalqon-agent-linux-amd64) | Oddiy serverlar, VM lar — 99% holat |
| `aarch64` | [`qalqon-agent-linux-arm64`](bin/qalqon-agent-linux-arm64) | ARM serverlar (Ampere, Graviton), RPi 4/5 (64-bit OS) |
| `armv7l`, `armv6l` | [`qalqon-agent-linux-armv7`](bin/qalqon-agent-linux-armv7) | RPi 2/3, 32-bit ARM SBC |
| `i686`, `i386` | [`qalqon-agent-linux-386`](bin/qalqon-agent-linux-386) | Eski 32-bit x86 |
| `riscv64` | [`qalqon-agent-linux-riscv64`](bin/qalqon-agent-linux-riscv64) | RISC-V |

### Sinovdan o'tgan distributivlar

| OS | Firewall qatlami |
|---|---|
| Ubuntu 22.04 / 24.04, Debian 12 | ufw |
| Rocky Linux 9, RHEL 9, AlmaLinux 9 | firewalld |

Boshqa systemd'li distributivlarda ham ishlaydi, lekin sinovdan o'tmagan.

### Talablar

- `systemd` va `curl`
- `root` huquqi (firewall, `/etc/shadow`, `/proc/*/fd` o'qish uchun)
- markaziy serverga **chiquvchi** HTTPS

Agentda **hech qanday port ochilmaydi** — u serverga o'zi murojaat qiladi,
shuning uchun NAT yoki qattiq firewall ortidagi serverlar ham boshqariladi.

---

## Qo'lda o'rnatish

```bash
ARCH=amd64        # uname -m ga qarab yuqoridagi jadvaldan
BASE=https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/bin

curl -fsSLO $BASE/qalqon-agent-linux-$ARCH
curl -fsSLO $BASE/qalqon-agent-linux-$ARCH.sha256
sha256sum -c qalqon-agent-linux-$ARCH.sha256          # OK bo'lishi shart

sudo install -m 0755 qalqon-agent-linux-$ARCH /usr/local/bin/qalqon-agent
qalqon-agent version
```

Keyin ro'yxatdan o'tkazish va servis:

```bash
sudo qalqon-agent enroll --server https://MARKAZIY-SERVER --token <TOKEN>
# ichki CA bo'lsa qo'shimcha:  --ca-cert /etc/ssl/certs/qalqon-ca.crt

sudo systemctl enable --now qalqon-agent
```

systemd unit fayli `install.sh` ichida — qo'lda o'rnatsangiz undan nusxa oling.

### Butunlikni tekshirish

```bash
curl -fsSLO https://raw.githubusercontent.com/shahz0dbek/qalqon-agent/main/bin/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

---

## Tekshirish

```bash
systemctl status qalqon-agent
journalctl -u qalqon-agent -f
qalqon-agent status           # mahalliy holat: ro'yxatdan o'tganmi, sozlama qayerda
qalqon-agent check            # hammasini mahalliy yig'ib chiqarish (serverga ulanmasdan)
```

Host markaziy serverning `/ui/hosts` sahifasida 1 daqiqa ichida `ONLINE`
bo'lib ko'rinishi kerak.

## O'chirish

```bash
sudo systemctl disable --now qalqon-agent qalqon-docker-fw
sudo rm -f /etc/systemd/system/qalqon-agent.service \
           /etc/systemd/system/qalqon-docker-fw.service
sudo systemctl daemon-reload
sudo rm -rf /usr/local/bin/qalqon-agent /var/lib/qalqon
```

Diqqat: `/var/lib/qalqon` da Docker firewall qoidalarining desired-state'i
saqlanadi. Uni o'chirsangiz qoidalar keyingi reboot dan keyin tiklanmaydi —
avval UI dan qoidalarni olib tashlang.

---

## Binarlar qanday qurilgan

Asosiy ombordagi [`agent/build.sh`](https://github.com/shahz0dbek/Qalqon/blob/main/agent/build.sh)
orqali, [`agent/targets.txt`](https://github.com/shahz0dbek/Qalqon/blob/main/agent/targets.txt)
dagi ro'yxat bo'yicha:

```
CGO_ENABLED=0 GOOS=linux GOARCH=<arch> go build -trimpath -ldflags "-s -w -X main.Version=<v>"
```

Bu omborni yangilash: `./deploy/publish-agent.sh ../qalqon-agent <versiya>`

Manba kodi, server qismi va to'liq hujjatlar:
**https://github.com/shahz0dbek/Qalqon**
