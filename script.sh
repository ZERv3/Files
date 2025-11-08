#!/usr/bin/env bash
# Ubuntu -> Minecraft DNAT helper with hairpin support
# Works with iptables-nft. Run as root: sudo ./setup-mc-forward.sh
set -e

# ===== Defaults (жми Enter, если ок) =====
DEFAULT_DST_IP="83.248.208.75"   # IP машины с Minecraft
DEFAULT_EXT_PORT="25565"         # внешний порт на Ubuntu
DEFAULT_DST_PORT="33300"         # порт на Minecraft-хосте
# ========================================

# --- utils ---
is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1
  done
  return 0
}
is_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le 65535 ]]
}

if [ "$EUID" -ne 0 ]; then
  echo "Запусти от root: sudo $0"; exit 1
fi

echo "=== Minecraft Port Forward Setup (Ubuntu NAT + hairpin) ==="
echo "(Enter = значения по умолчанию в квадратных скобках)"
echo

# Автоопределение публичного IP
PUBLIC_IP="$(curl -s -4 ifconfig.me || true)"
if ! is_ipv4 "$PUBLIC_IP"; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if ! is_ipv4 "$PUBLIC_IP"; then
  echo "⚠️  Не удалось автоопределить внешний IP. Введи руками:"
  read -rp "Public IP of THIS Ubuntu: " PUBLIC_IP
  is_ipv4 "$PUBLIC_IP" || { echo "Неверный IP"; exit 1; }
fi
echo "Detected public IP: $PUBLIC_IP"
echo

# Ввод с дефолтами
read -rp "Destination IP (Minecraft host) [${DEFAULT_DST_IP}]: " DST_IP
DST_IP="${DST_IP:-$DEFAULT_DST_IP}"
is_ipv4 "$DST_IP" || { echo "❌ Неверный IPv4: $DST_IP"; exit 1; }

read -rp "External port on THIS Ubuntu [${DEFAULT_EXT_PORT}]: " EXT_PORT
EXT_PORT="${EXT_PORT:-$DEFAULT_EXT_PORT}"
is_port "$EXT_PORT" || { echo "❌ Неверный порт: $EXT_PORT"; exit 1; }

read -rp "Destination port on Minecraft host [${DEFAULT_DST_PORT}]: " DST_PORT
DST_PORT="${DST_PORT:-$DEFAULT_DST_PORT}"
is_port "$DST_PORT" || { echo "❌ Неверный порт: $DST_PORT"; exit 1; }

echo
echo "Ubuntu (public): ${PUBLIC_IP}:${EXT_PORT}"
echo "Minecraft host : ${DST_IP}:${DST_PORT}"
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
IFACE="${IFACE:-eth0}"
echo "Iface guess    : ${IFACE}"
echo

read -rp "Proceed (flush & apply rules)? [y/N] " ok
[[ "$ok" =~ ^[yY]$ ]] || { echo "Отмена."; exit 0; }

# Бэкап текущих правил
BK="/root/iptables-backup-$(date +%s).rules"
iptables-save > "$BK" || true
echo "Снял бэкап iptables: $BK"

# Включаем форвардинг (runtime + persist)
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Чистим только нужные цепочки
iptables -t nat -F PREROUTING || true
iptables -t nat -F POSTROUTING || true
iptables -t nat -F OUTPUT || true
iptables -F FORWARD || true

# ===== Правила =====
# 1) Внешние клиенты: DNAT в PREROUTING
iptables -t nat -A PREROUTING  -p tcp --dport "$EXT_PORT" -j DNAT --to-destination "${DST_IP}:${DST_PORT}"

# 2) Локальные/через собственный VPN на этом же хосте (hairpin):
#    если обращаемся к СВОЕМУ public IP:EXT_PORT — DNAT в OUTPUT
iptables -t nat -A OUTPUT -p tcp -d "$PUBLIC_IP" --dport "$EXT_PORT" -j DNAT --to-destination "${DST_IP}:${DST_PORT}"

# 3) SNAT/MASQ: чтобы ответы шли обратно через Ubuntu
iptables -t nat -A POSTROUTING -p tcp -d "$DST_IP" --dport "$DST_PORT" -j MASQUERADE

# 4) Разрешаем транзит для внешних потоков (локальные OUTPUT в FORWARD не ходят)
iptables -A FORWARD -p tcp -d "$DST_IP" --dport "$DST_PORT" \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -p tcp -s "$DST_IP" --sport "$DST_PORT" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# ===================

echo
echo "=== NAT table ==="
iptables -t nat -L -n -v
echo
echo "=== FORWARD chain ==="
iptables -L FORWARD -n -v
echo

cat <<EOF

✅ Готово.

Тесты:
  [С клиента]  nc -vz ${PUBLIC_IP} ${EXT_PORT}
  [Ubuntu]     sudo tcpdump -ni ${IFACE} tcp port ${EXT_PORT} -n
  [Minecraft]  sudo tcpdump -ni any tcp port ${DST_PORT} -n
  [Minecraft]  убедись, что java слушает порт:
               sudo lsof -iTCP -sTCP:LISTEN -P | grep ${DST_PORT}

Если сидишь за своим же VPN с выходом ${PUBLIC_IP}, hairpin уже учтён (DNAT в OUTPUT).

EOF

read -rp "Сохранить правила (iptables-persistent)? [y/N] " save
if [[ "$save" =~ ^[yY]$ ]]; then
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent
  fi
  netfilter-persistent save
  echo "✅ Правила сохранены."
else
  echo "ℹ️  После ребута правила слетят. Сохрани через netfilter-persistent при желании."
fi