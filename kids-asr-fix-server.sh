#!/bin/bash
# 少儿英语 ASR 403 修复脚本 —— 直接在阿里云服务器上以 root 运行
# 用法（在服务器终端里粘贴这一行）：
#   curl -sSL https://raw.githubusercontent.com/geneadela284-glitch/kids-english-unit1-demo/main/kids-asr-fix-server.sh | bash
# 原理：页面口令 kids-ep1-2026 已公开写在体验页源码里；修服务端让它认这个口令，不动页面、不动 ERP。
# 全程只打印口令的 sha256、不打印口令本身。
set -u
PAGE_TOKEN="kids-ep1-2026"
echo "== 1 kids-asr 服务状态 =="
systemctl is-active kids-asr || true
echo "== 2 口令配置位置（值已遮盖） =="
grep -rn "KIDS_TOKEN" /opt/kids-asr/ /etc/systemd/system/kids-asr* 2>/dev/null | sed 's/=.*/=<masked>/' | head || echo "no KIDS_TOKEN match"
echo "== 3 哈希比对 =="
PAGE_HASH=$(printf '%s' "$PAGE_TOKEN" | sha256sum | awk '{print $1}')
echo "page token sha256: $PAGE_HASH"
SRV_TOKEN=""; SRV_FILE=""; VARNAME=""
for f in /opt/kids-asr/.env /opt/kids-asr/config.env /opt/kids-asr/app.env /etc/kids-asr.env; do
  if [ -f "$f" ] && grep -q -E "KIDS_TOKEN|TOKEN" "$f" 2>/dev/null; then
    line=$(grep -h -E "KIDS_TOKEN|TOKEN" "$f" | head -1)
    VARNAME=$(printf '%s' "$line" | cut -d= -f1 | tr -d ' ')
    SRV_TOKEN=$(printf '%s' "$line" | cut -d= -f2- | tr -d '"'"' ')
    SRV_FILE="$f"; break
  fi
done
if [ -z "$SRV_TOKEN" ]; then
  unit_line=$(systemctl cat kids-asr 2>/dev/null | grep -E "Environment=.*TOKEN" | head -1 || true)
  if [ -n "$unit_line" ]; then
    VARNAME=$(printf '%s' "$unit_line" | grep -o "KIDS_TOKEN\|[A-Z_]*TOKEN[A-Z_]*" | head -1)
    SRV_TOKEN=$(printf '%s' "$unit_line" | sed 's/.*'"$VARNAME"'=//;s/ .*//')
    SRV_FILE="systemd-unit"
  fi
fi
if [ -z "$SRV_TOKEN" ]; then
  echo "ABORT: server token not located"
  ls -la /opt/kids-asr/ 2>/dev/null || true
  systemctl cat kids-asr 2>/dev/null | head -30 || true
  exit 1
fi
SRV_HASH=$(printf '%s' "$SRV_TOKEN" | sha256sum | awk '{print $1}')
echo "server token source: $SRV_FILE (var $VARNAME)"
echo "server token sha256: $SRV_HASH"
if [ "$SRV_HASH" = "$PAGE_HASH" ]; then
  echo "MATCH: tokens agree - 403 has another cause:"
  journalctl -u kids-asr --since "2026-11-25 00:00" --no-pager 2>/dev/null | tail -15 || true
  exit 2
fi
echo "MISMATCH: setting server token to the page token and restarting"
if [ "$SRV_FILE" = "systemd-unit" ]; then
  mkdir -p /etc/systemd/system/kids-asr.service.d
  printf '[Service]\nEnvironment=%s=%s\n' "$VARNAME" "$PAGE_TOKEN" > /etc/systemd/system/kids-asr.service.d/token.conf
  systemctl daemon-reload
else
  sed -i "s|^$VARNAME=.*|$VARNAME=$PAGE_TOKEN|" "$SRV_FILE"
  grep "^$VARNAME=" "$SRV_FILE" | sed 's/=.*/=<masked>/'
fi
systemctl restart kids-asr
sleep 2
systemctl is-active kids-asr || true
echo "== 4 端到端验证（期望 HTTP 200，不再是 403） =="
python3 -c "
import wave,struct
w=wave.open('/tmp/kids-test.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b''.join(struct.pack('<h',0) for _ in range(16000))); w.close()" 2>/dev/null || echo "no python3 for wav gen"
curl -s -o /tmp/kids-asr-resp.txt -w "POST transcribe -> HTTP %{http_code} in %{time_total}s\n" \
  -H "X-Kids-Token: $PAGE_TOKEN" -H "Content-Type: audio/wav" \
  --data-binary @/tmp/kids-test.wav "https://huage-erp.kdns.fr/asr/transcribe?lang=en" || echo "curl failed"
head -c 300 /tmp/kids-asr-resp.txt; echo
echo "== DONE =="
