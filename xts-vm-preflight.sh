#!/usr/bin/env bash
# xTS Insight — 公司內網 VM 部署前檢查（唯讀，不安裝、不改任何設定）
#
# 用法：
#   bash xts-vm-preflight.sh
#   REDMINE_URL=https://redmine.xxx GITILES_URL=https://gitiles.xxx bash xts-vm-preflight.sh   # 選填：內網服務
#
# 結果同時存到 ./xts-preflight-<hostname>-<時間>.txt，整份貼回來即可。
# 不需要 sudo；有 sudo -n 權限時會多看防火牆狀態（不會跳密碼提示）。

set -u
TIMEOUT=${TIMEOUT:-8}
OUT="./xts-preflight-$(hostname -s 2>/dev/null || echo vm)-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

PASS=(); FAIL=(); INFO=()
ok()   { echo "  ✅ $*"; PASS+=("$*"); }
ng()   { echo "  ❌ $*"; FAIL+=("$*"); }
note() { echo "  ℹ️  $*"; INFO+=("$*"); }
hdr()  { echo; echo "=== $* ==="; }
has()  { command -v "$1" >/dev/null 2>&1; }
# 遮掉 proxy URL 裡的帳密（http://user:pass@host → http://***@host）
mask() { sed -E 's#(://)[^/@]+@#\1***@#g'; }

echo "xTS Insight VM preflight — $(date '+%F %T %Z')"

# ---------------------------------------------------------------- 1. 主機
hdr "1. 主機基本資訊"
echo "  hostname : $(hostname -f 2>/dev/null || hostname)"
echo "  IP       : $(hostname -I 2>/dev/null || echo '?')"
[ -r /etc/os-release ] && echo "  OS       : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  kernel   : $(uname -r)   arch: $(uname -m)"
[ "$(uname -m)" = "x86_64" ] && ok "x86_64（離線 wheel 用 manylinux x86_64）" || ng "架構 $(uname -m)：wheel/Python tarball 要換對應版本"
if has ldd; then echo "  glibc    : $(ldd --version 2>&1 | head -1)"; fi
echo "  CPU      : $(nproc 2>/dev/null || echo '?') cores"
has free && free -h | sed 's/^/  /'
echo "  磁碟（/opt、/var/lib、/tmp）:"
df -h /opt /var/lib /tmp 2>/dev/null | sed 's/^/    /'
echo "  whoami   : $(whoami)   groups: $(id -Gn)"
if sudo -n true 2>/dev/null; then ok "可免密碼 sudo"; else note "sudo 需要密碼（安裝時需要 sudo，正常）"; fi

# ---------------------------------------------------------------- 2. Python
hdr "2. Python（xTS Insight 開發用 3.13；dashboard_eis 用 3.12）"
for p in python3 python3.10 python3.11 python3.12 python3.13 /opt/python3.12/bin/python3.12 /opt/python3.13/bin/python3.13; do
  if has "$p" || [ -x "$p" ]; then echo "  $p → $("$p" --version 2>&1)"; fi
done
if [ -x /opt/python3.12/bin/python3.12 ] || has python3.12 || has python3.13 || [ -x /opt/python3.13/bin/python3.13 ]; then
  ok "已有 Python 3.12+（可沿用 dashboard_eis 裝的 /opt/python3.12）"
else
  ng "沒有 Python 3.12+：要帶 python-build-standalone tarball"
fi

# ---------------------------------------------------------------- 3. 工具與容器
hdr "3. 工具 / Docker / nginx"
for t in git rsync curl sqlite3 systemctl tar; do
  if has "$t"; then ok "$t: $($t --version 2>&1 | head -1)"; else ng "$t 不存在"; fi
done

if has docker; then
  ok "docker: $(docker --version 2>&1)"
  if docker info >/dev/null 2>&1; then ok "目前帳號可直接跑 docker"
  elif sudo -n docker info >/dev/null 2>&1; then note "docker 需 sudo"
  else note "docker 存在但目前帳號無權限（或 daemon 沒跑）"; fi
  if docker compose version >/dev/null 2>&1; then ok "docker compose: $(docker compose version 2>&1 | head -1)"
  elif has docker-compose; then ok "docker-compose: $(docker-compose --version)"
  else note "沒有 docker compose"; fi
  docker images --format '  image: {{.Repository}}:{{.Tag}} ({{.Size}})' 2>/dev/null | head -10
else
  note "沒有 docker → 走 systemd + venv（同 dashboard_eis）"
fi
has podman && note "podman: $(podman --version)"

if has nginx; then
  ok "nginx: $(nginx -v 2>&1)"
  systemctl is-active nginx >/dev/null 2>&1 && ok "nginx 執行中" || note "nginx 有裝但沒在跑"
  ls /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | sed 's/^/    /'
else
  note "沒有 nginx → 前端需由 FastAPI 直接 serve"
fi

# ---------------------------------------------------------------- 4. 既有服務與 port
hdr "4. 既有服務與 port 佔用"
if has systemctl; then
  for s in eis-mcp nginx docker postgresql; do
    st=$(systemctl is-active "$s" 2>/dev/null); [ -n "$st" ] && echo "  $s: $st"
  done
fi
if has ss; then
  echo "  LISTEN 中的 TCP port："
  ss -ltnH 2>/dev/null | awk '{print $4}' | sort -u | sed 's/^/    /'
  for p in 80 443 8002 8080 8765 9001; do
    if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then note "port $p 已被佔用"; else ok "port $p 可用"; fi
  done
else
  note "沒有 ss 指令，略過 port 檢查"
fi

hdr "4b. 防火牆（需 sudo -n，否則略過）"
if sudo -n true 2>/dev/null; then
  has ufw && sudo -n ufw status 2>/dev/null | sed 's/^/  /'
  has firewall-cmd && sudo -n firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'
else
  note "無免密碼 sudo，略過；請另外跟 IT 確認哪些網段能連進這台 VM"
fi
has getenforce && note "SELinux: $(getenforce)"

# ---------------------------------------------------------------- 5. Proxy
hdr "5. Proxy 環境變數（帳密已遮罩）"
found=0
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY all_proxy ALL_PROXY; do
  if [ -n "${!v:-}" ]; then echo "  $v=${!v}" | mask; found=1; fi
done
[ $found -eq 0 ] && note "沒有設定 proxy 環境變數（systemd 服務預設也不會有）"
has git && git config --global --get http.proxy 2>/dev/null | mask | sed 's/^/  git http.proxy=/'
[ -f /etc/apt/apt.conf.d/proxy.conf ] && sed 's/^/  apt: /' /etc/apt/apt.conf.d/proxy.conf | mask

# ---------------------------------------------------------------- 6. 對外連線
# 每個目標測兩次：照目前環境（可能走 proxy）與強制直連（--noproxy '*'，等同 systemd 服務的處境）
# HTTP 狀態碼；TLS 憑證不受信任（公司 CA）時 curl 回 000，改標成 TLS 讓「網路通、只是憑證」可分辨
curl_code() {  # curl_code <URL> [額外 curl 參數...]
  local url=$1; shift
  local code rc
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$@" "$url" 2>/dev/null); rc=$?
  case $rc in
    60|35|51|58|77|83) echo "TLS" ;;   # 憑證/握手問題 → 網路其實通
    *) echo "${code:-000}" ;;
  esac
}

probe() {  # probe <名稱> <URL> <用途>
  local name=$1 url=$2 why=$3 host code_env code_direct
  host=$(echo "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  local dns; dns=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
  code_env=$(curl_code "$url"); code_direct=$(curl_code "$url" --noproxy '*')
  local line; line=$(printf '%-22s DNS=%-15s 目前環境=%s 直連=%s  (%s)' "$name" "${dns:--}" "$code_env" "$code_direct" "$why")
  if [ "$code_direct" != "000" ]; then ok "$line"
  elif [ "$code_env" != "000" ]; then note "$line ← 只有走 proxy 才通"
  else ng "$line"; fi
}

hdr "6. 對外 / 內網連線（000 = 連不上；4xx 也代表網路通；TLS = 網路通但憑證不受信任）"
probe "PyPI"           "https://pypi.org/simple/pip/"                "線上 pip install"
probe "PyPI files"     "https://files.pythonhosted.org/"             "wheel 下載"
probe "GitHub"         "https://github.com/"                         "git clone 程式碼"
probe "GitHub release" "https://objects.githubusercontent.com/"      "python-build-standalone 下載"
probe "GHCR"           "https://ghcr.io/v2/"                         "拉現有 docker image"
probe "Docker Hub"     "https://registry-1.docker.io/v2/"            "docker pull"
probe "npm registry"   "https://registry.npmjs.org/"                 "VM 上 build 前端（通常不需要）"
probe "Ubuntu apt"     "http://archive.ubuntu.com/ubuntu/"           "apt install"
probe "Cambrian"       "https://api.cambrian.pegatroncorp.com/"      "AI 分析 LLM（必要）"
probe "AOSP Gitiles"   "https://android.googlesource.com/?format=TEXT" "source context"
probe "OpenAI"         "https://api.openai.com/v1/models"            "OpenAI provider（預期不通）"
[ -n "${REDMINE_URL:-}" ] && probe "Redmine"        "$REDMINE_URL"  "Redmine issue 草稿"
[ -n "${GITILES_URL:-}" ] && probe "內網 Gitiles"  "$GITILES_URL"  "內網 source context"

# Cambrian 的 TLS：程式用 verify=False，這裡只看憑證是否為公司 CA（資訊用）
if has openssl; then
  issuer=$(echo | timeout "$TIMEOUT" openssl s_client -connect api.cambrian.pegatroncorp.com:443 \
           -servername api.cambrian.pegatroncorp.com 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
  [ -n "$issuer" ] && note "Cambrian 憑證 $issuer"
fi

# git 協定（Gitiles 建 file index 用 git ls-remote / clone；只抓 refs，不下載內容）
if has git; then
  if GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote --heads \
       https://android.googlesource.com/platform/test/vts-testcase/hal >/dev/null 2>&1; then
    ok "git ls-remote android.googlesource.com 可用"
  else
    ng "git ls-remote android.googlesource.com 失敗 → source context 建議關閉或改指內網鏡像"
  fi
  if GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote https://github.com/git/git.git HEAD >/dev/null 2>&1; then
    ok "git ls-remote github.com（公開 repo）可用"
  else
    ng "git ls-remote github.com（公開 repo）失敗"
  fi
  # VM 的 GitHub 憑證能讀哪些 private repo（deploy key 只綁單一 repo；帳號 key 全部可讀）
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=$TIMEOUT"
  for r in dashboard_eis gms-helper-v2; do
    if GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" git ls-remote "git@github.com:seen0722/$r.git" HEAD >/dev/null 2>&1; then
      ok "可讀 private repo seen0722/$r（ssh）"
    else
      ng "讀不到 private repo seen0722/$r（ssh）→ VM 的 key 可能是只綁 dashboard_eis 的 deploy key"
    fi
  done
  unset GIT_SSH_COMMAND
fi

# ---------------------------------------------------------------- 7. 摘要
hdr "摘要"
echo "  ✅ ${#PASS[@]}   ❌ ${#FAIL[@]}   ℹ️  ${#INFO[@]}"
if [ ${#FAIL[@]} -gt 0 ]; then echo "  失敗項目："; printf '    - %s\n' "${FAIL[@]}"; fi
echo
echo "結果已存到 $OUT ，整份貼回來即可（proxy 帳密已遮罩；內容不含任何 token）。"
