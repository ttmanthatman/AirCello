#!/usr/bin/env bash
#
# Air Cello — 统一管理脚本 v2.0
# 用法：
#   sudo ./deploy-aircello.sh            # 交互菜单（自动检测部署状态）
#   sudo ./deploy-aircello.sh update     # 非交互：拉取更新
#   sudo ./deploy-aircello.sh status     # 非交互：查看状态
#   sudo ./deploy-aircello.sh logs       # 非交互：查看日志
#
set -euo pipefail

# ============================================================
# 颜色 & 输出工具
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}▶ $*${NC}" >&2; }
sep()   { echo -e "${DIM}────────────────────────────────────────${NC}" >&2; }

# ============================================================
# Root 权限检查
# ============================================================
if [[ $EUID -ne 0 ]]; then
  err "请使用 sudo 运行此脚本：sudo ./deploy-aircello.sh"
fi

# ============================================================
# 常量 & 配置文件搜索
# ============================================================
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
DEFAULT_INSTALL_DIR="/var/www/aircello"
BACKUP_KEEP=5  # 保留最近几个备份

# 按优先级搜索配置文件
CONFIG_FILE=""
for _candidate in \
  "${SCRIPT_DIR}/.aircello-deploy.conf" \
  "${DEFAULT_INSTALL_DIR}/.aircello-deploy.conf"; do
  if [[ -f "$_candidate" ]]; then
    CONFIG_FILE="$_candidate"
    break
  fi
done

IS_DEPLOYED=false
if [[ -n "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  IS_DEPLOYED=true
fi

# ============================================================
# 打印 Banner
# ============================================================
print_banner() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     🎻  Air Cello 管理脚本 v2.0       ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
  echo ""
}

# ============================================================
# 快速状态检测（Banner 下方显示）
# ============================================================
print_quick_status() {
  if [[ "$IS_DEPLOYED" == false ]]; then
    echo -e "  ${YELLOW}⚠  未检测到部署配置，请先执行首次部署${NC}"
    echo ""
    return
  fi

  local nginx_status ssl_status git_status
  local nginx_color ssl_color git_color

  # Nginx
  if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx_status="运行中"; nginx_color="${GREEN}"
  else
    nginx_status="已停止"; nginx_color="${RED}"
  fi

  # SSL 有效期
  local cert_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if [[ -f "$cert_file" ]]; then
    local expiry_str expiry_epoch now_epoch days_left
    expiry_str=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left > 14 )); then
      ssl_status="有效（剩 ${days_left}d）"; ssl_color="${GREEN}"
    elif (( days_left > 0 )); then
      ssl_status="即将到期（剩 ${days_left}d）"; ssl_color="${YELLOW}"
    else
      ssl_status="已过期"; ssl_color="${RED}"
    fi
  else
    ssl_status="未配置"; ssl_color="${YELLOW}"
  fi

  # GitHub 新提交检测
  local source_dir="${INSTALL_DIR}/source"
  if [[ -d "${source_dir}/.git" ]]; then
    cd "$source_dir"
    git fetch origin "${GIT_BRANCH}" --quiet 2>/dev/null || true
    local local_commit remote_commit
    local_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
    remote_commit=$(git rev-parse --short "origin/${GIT_BRANCH}" 2>/dev/null || echo "?")
    if [[ "$local_commit" == "$remote_commit" ]]; then
      git_status="最新 (${local_commit})"; git_color="${GREEN}"
    else
      git_status="有新提交 ${local_commit}→${remote_commit}"; git_color="${YELLOW}"
    fi
  else
    git_status="源码目录不存在"; git_color="${RED}"
  fi

  echo -e "  域名：    ${GREEN}https://${DOMAIN}${NC}"
  echo -e "  Nginx：   ${nginx_color}${nginx_status}${NC}"
  echo -e "  SSL：     ${ssl_color}${ssl_status}${NC}"
  echo -e "  GitHub：  ${git_color}${git_status}${NC}"
  echo ""
}

# ============================================================
# 公共：构建项目
# 注意：此函数通过 detected_build=$(do_build ...) 调用
#       stdout 只能输出最终路径，所有日志/命令输出必须走 stderr
# ============================================================
do_build() {
  local source_dir="$1"
  cd "$source_dir"

  if [[ -f "package.json" ]]; then
    info "安装 npm 依赖..."
    if [[ -f "package-lock.json" ]]; then
      npm ci --prefer-offline --no-audit --no-fund 2>&1 | tail -1 >&2
    else
      warn "未找到 package-lock.json，使用 npm install"
      npm install --no-audit --no-fund 2>&1 | tail -1 >&2
    fi
    ok "依赖安装完成"

    if node -e "const p=require('./package.json'); process.exit(p.scripts?.build ? 0 : 1)" 2>/dev/null; then
      info "构建项目..."
      npm run build 2>&1 | tail -3 >&2
      ok "构建完成"
    else
      warn "package.json 未定义 build 脚本，跳过构建"
    fi
  fi

  # 检测构建输出目录
  local detected=""
  for candidate in dist build out .next/static public; do
    if [[ -d "${source_dir}/${candidate}" ]]; then
      detected="${source_dir}/${candidate}"
      break
    fi
  done
  if [[ -z "$detected" && -f "${source_dir}/index.html" ]]; then
    detected="${source_dir}"
    info "检测到纯静态项目（根目录 index.html）"
  fi
  if [[ -z "$detected" ]]; then
    err "未找到构建输出（尝试了 dist/ build/ out/ public/ 及根目录），请检查项目结构"
  fi

  # 唯一写 stdout 的地方——调用方通过 $() 捕获路径
  echo "$detected"
}

# ============================================================
# 公共：部署构建产物 + 保留 N 个备份
# ============================================================
do_deploy_build() {
  local detected_build="$1"
  local source_dir="${INSTALL_DIR}/source"
  local build_dir="${INSTALL_DIR}/build"

  # 备份旧版本
  if [[ -d "$build_dir" ]]; then
    local backup="${build_dir}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$build_dir" "$backup"
    info "旧版本已备份至 $(basename "$backup")"

    # 只保留最近 BACKUP_KEEP 个备份
    local -a backups
    mapfile -t backups < <(find "${INSTALL_DIR}" -maxdepth 1 -name "build.bak.*" \
      -type d | sort -r)
    local count=${#backups[@]}
    if (( count > BACKUP_KEEP )); then
      for (( i=BACKUP_KEEP; i<count; i++ )); do
        rm -rf "${backups[$i]}"
        info "清理旧备份：$(basename "${backups[$i]}")"
      done
    fi
    info "当前保留备份：$((count > BACKUP_KEEP ? BACKUP_KEEP : count)) 个"
  fi

  # 复制新产物
  if [[ "$detected_build" == "$source_dir" ]]; then
    mkdir -p "$build_dir"
    rsync -a \
      --exclude='.git' \
      --exclude='node_modules' \
      --exclude='.aircello-deploy.conf' \
      "${source_dir}/" "${build_dir}/"
  else
    # 用 rsync 复制构建产物内容（而非目录本身），避免产生 build/dist/ 嵌套
    mkdir -p "$build_dir"
    rsync -a "${detected_build}/" "${build_dir}/"
  fi
  chown -R www-data:www-data "$build_dir"
  chmod -R 755 "$build_dir"
  ok "新版本已部署至 ${build_dir}"
}

# ============================================================
# 操作 [1]：拉取更新
# ============================================================
action_update() {
  step "拉取更新"
  local source_dir="${INSTALL_DIR}/source"

  if [[ ! -d "${source_dir}/.git" ]]; then
    err "源码目录不存在：${source_dir}\n请先执行【重新部署】"
  fi

  cd "$source_dir"
  local before
  before=$(git rev-parse --short HEAD)

  info "拉取远程代码..."
  git fetch origin
  git checkout "$GIT_BRANCH"
  git reset --hard "origin/${GIT_BRANCH}"

  local after
  after=$(git rev-parse --short HEAD)

  if [[ "$before" == "$after" ]]; then
    warn "代码未变化（${before}）"
    if [[ "${NON_INTERACTIVE:-false}" == true ]]; then
      info "非交互模式：跳过重新构建"
      return 0
    fi
    read -rp "$(echo -e "${YELLOW}仍要重新构建并部署？(y/N)：${NC}")" force
    if [[ "$force" != "y" && "$force" != "Y" ]]; then
      info "已取消"; return 0
    fi
  else
    info "代码更新：${before} → ${after}"
    echo -e "  ${DIM}$(git log --oneline -1)${NC}"
  fi

  local detected_build
  detected_build=$(do_build "$source_dir")

  do_deploy_build "$detected_build"

  info "重载 Nginx..."
  nginx -t 2>&1 || err "Nginx 配置异常"
  systemctl reload nginx

  sep
  ok "更新完成！"
  echo -e "  版本：${GREEN}${after}${NC}"
  echo -e "  地址：${GREEN}https://${DOMAIN}${NC}"
  echo ""
}

# ============================================================
# 操作 [2]：重新部署（使用已有配置，走完整流程）
# ============================================================
action_redeploy() {
  step "重新部署"
  echo -e "  将使用已保存配置重走完整部署流程："
  echo -e "  域名：${GREEN}${DOMAIN}${NC}"
  echo -e "  仓库：${GREEN}${GIT_REPO}${NC}"
  echo -e "  分支：${GREEN}${GIT_BRANCH}${NC}"
  echo -e "  目录：${GREEN}${INSTALL_DIR}${NC}"
  echo ""

  if [[ "${NON_INTERACTIVE:-false}" == false ]]; then
    read -rp "$(echo -e "${YELLOW}确认重新部署？(y/N)：${NC}")" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      info "已取消"; return 0
    fi
  fi

  run_deploy_flow
}

# ============================================================
# 操作 [3]：查看状态（详细版）
# ============================================================
action_status() {
  step "系统状态"

  # ── Nginx ──────────────────────────────────────────
  echo -e "\n${BOLD}Nginx${NC}"
  if systemctl is-active --quiet nginx; then
    ok "运行中"
    echo -e "  版本：$(nginx -v 2>&1)"
    echo -e "  进程：$(pgrep -c nginx || echo 0) 个 worker"
  else
    warn "已停止（sudo systemctl start nginx）"
  fi

  # ── SSL 证书 ────────────────────────────────────────
  echo -e "\n${BOLD}SSL 证书${NC}"
  local cert_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if [[ -f "$cert_file" ]]; then
    local expiry_str expiry_epoch now_epoch days_left
    expiry_str=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left > 14 )); then
      ok "有效，到期：${expiry_str}（剩余 ${days_left} 天）"
    elif (( days_left > 0 )); then
      warn "即将到期：${expiry_str}（剩余 ${days_left} 天）"
      warn "手动续期：sudo certbot renew"
    else
      err "证书已过期！"
    fi
    echo -e "  自动续期：$(systemctl is-active certbot.timer 2>/dev/null || echo 未启用)"
  else
    warn "未找到证书文件：${cert_file}"
    warn "重新申请：sudo certbot --nginx -d ${DOMAIN}"
  fi

  # ── GitHub ─────────────────────────────────────────
  echo -e "\n${BOLD}GitHub 仓库${NC}"
  local source_dir="${INSTALL_DIR}/source"
  if [[ -d "${source_dir}/.git" ]]; then
    cd "$source_dir"
    info "正在检查远程仓库..."
    git fetch origin "${GIT_BRANCH}" --quiet 2>/dev/null || warn "无法连接远程仓库"

    local local_commit remote_commit local_date
    local_commit=$(git rev-parse HEAD)
    remote_commit=$(git rev-parse "origin/${GIT_BRANCH}" 2>/dev/null || echo "")
    local_date=$(git log -1 --format="%ci" 2>/dev/null)

    echo -e "  本地：${local_commit:0:8}  ${DIM}${local_date}${NC}"
    echo -e "  最新：$(git log --oneline -1)"

    if [[ -n "$remote_commit" && "$local_commit" != "$remote_commit" ]]; then
      local new_count
      new_count=$(git rev-list HEAD..origin/"${GIT_BRANCH}" --count 2>/dev/null || echo "?")
      warn "远程有 ${new_count} 个新提交，可执行【拉取更新】"
      echo -e "\n  ${DIM}新提交预览：${NC}"
      git log --oneline HEAD..origin/"${GIT_BRANCH}" 2>/dev/null | head -5 | \
        while IFS= read -r line; do echo -e "  ${DIM}  ${line}${NC}"; done
    else
      ok "已是最新"
    fi
  else
    warn "源码目录不存在：${source_dir}"
  fi

  # ── 磁盘 & 备份 ────────────────────────────────────
  echo -e "\n${BOLD}磁盘 & 备份${NC}"
  if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "  安装目录总占用：$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1)"
    echo -e "  当前构建：$(du -sh "${INSTALL_DIR}/build" 2>/dev/null | cut -f1 || echo '不存在')"
    local backup_count
    backup_count=$(find "${INSTALL_DIR}" -maxdepth 1 -name "build.bak.*" -type d 2>/dev/null | wc -l)
    echo -e "  历史备份：${backup_count} 个（最多保留 ${BACKUP_KEEP} 个）"
  fi

  # ── 部署信息 ───────────────────────────────────────
  echo -e "\n${BOLD}部署信息${NC}"
  echo -e "  域名：      ${GREEN}https://${DOMAIN}${NC}"
  echo -e "  仓库：      ${GIT_REPO}"
  echo -e "  分支：      ${GIT_BRANCH}"
  echo -e "  安装目录：  ${INSTALL_DIR}"
  echo -e "  上次部署：  ${DEPLOYED_AT:-未知}"
  echo ""
}

# ============================================================
# 操作 [4]：查看日志
# ============================================================
action_logs() {
  step "Nginx 日志"

  local access_log="/var/log/nginx/aircello.access.log"
  local error_log="/var/log/nginx/aircello.error.log"
  local lines=50

  echo -e "\n${BOLD}── 访问日志（最近 ${lines} 行）──${NC}"
  if [[ -f "$access_log" ]]; then
    tail -n "$lines" "$access_log"
  else
    warn "访问日志不存在：${access_log}"
  fi

  echo -e "\n${BOLD}── 错误日志（最近 ${lines} 行）──${NC}"
  if [[ -f "$error_log" ]]; then
    tail -n "$lines" "$error_log"
  else
    warn "错误日志不存在：${error_log}"
  fi

  if [[ "${NON_INTERACTIVE:-false}" == false ]]; then
    echo ""
    read -rp "$(echo -e "${YELLOW}持续监听实时日志？(y/N)：${NC}")" tail_mode
    if [[ "$tail_mode" == "y" || "$tail_mode" == "Y" ]]; then
      echo -e "${DIM}（按 Ctrl+C 退出）${NC}\n"
      tail -f "$access_log" "$error_log" 2>/dev/null || warn "日志文件不存在"
    fi
  fi
}

# ============================================================
# 操作 [5]：卸载
# ============================================================
action_uninstall() {
  step "卸载 Air Cello"
  echo ""
  echo -e "  ${RED}${BOLD}⚠  以下内容将被永久删除：${NC}"
  echo -e "  • SSL 证书：${DOMAIN}"
  echo -e "  • Nginx 站点配置"
  echo -e "  • 安装目录：${INSTALL_DIR}（含源码、构建产物及所有备份）"
  echo ""
  warn "此操作不可撤销！"
  echo ""
  read -rp "$(echo -e "${RED}请输入域名 ${DOMAIN} 以确认卸载：${NC}")" confirm_domain
  if [[ "$confirm_domain" != "$DOMAIN" ]]; then
    info "输入不匹配，已取消卸载"; return 0
  fi

  # 1. 删除 SSL 证书
  info "删除 SSL 证书..."
  certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null && \
    ok "SSL 证书已删除" || warn "证书删除失败（可能不存在），跳过"

  # 2. 移除 Nginx 配置
  info "移除 Nginx 配置..."
  rm -f "/etc/nginx/sites-enabled/aircello"
  rm -f "/etc/nginx/sites-available/aircello"
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    ok "Nginx 配置已移除并重载"
  else
    warn "Nginx 配置检查失败，请手动检查"
  fi

  # 3. 删除安装目录
  info "删除安装目录 ${INSTALL_DIR}..."
  rm -rf "$INSTALL_DIR"
  ok "安装目录已删除"

  sep
  ok "卸载完成"
  echo -e "  ${DIM}Nginx 与 Node.js 已保留（系统级依赖，如需卸载请手动执行）${NC}"
  echo ""
}

# ============================================================
# 首次部署向导（收集配置）
# ============================================================
deploy_wizard() {
  step "首次部署配置"

  read -rp "$(echo -e "${YELLOW}请输入域名（如 cello.example.com）：${NC}")" DOMAIN
  [[ -z "$DOMAIN" ]] && err "域名不能为空"

  read -rp "$(echo -e "${YELLOW}请输入 Git 仓库地址（HTTPS）：${NC}")" GIT_REPO
  [[ -z "$GIT_REPO" ]] && err "仓库地址不能为空"

  read -rp "$(echo -e "${YELLOW}请输入 Git 分支 [main]：${NC}")" GIT_BRANCH
  GIT_BRANCH=${GIT_BRANCH:-main}

  read -rp "$(echo -e "${YELLOW}请输入安装目录 [${DEFAULT_INSTALL_DIR}]：${NC}")" INSTALL_DIR
  INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}

  read -rp "$(echo -e "${YELLOW}请输入 SSL 邮箱（Let's Encrypt 通知用）：${NC}")" SSL_EMAIL
  [[ -z "$SSL_EMAIL" ]] && err "邮箱不能为空"

  echo ""
  echo -e "${CYAN}─────── 配置确认 ───────${NC}"
  echo -e "  域名：     ${GREEN}${DOMAIN}${NC}"
  echo -e "  仓库：     ${GREEN}${GIT_REPO}${NC}"
  echo -e "  分支：     ${GREEN}${GIT_BRANCH}${NC}"
  echo -e "  目录：     ${GREEN}${INSTALL_DIR}${NC}"
  echo -e "  邮箱：     ${GREEN}${SSL_EMAIL}${NC}"
  echo -e "${CYAN}────────────────────────${NC}"
  echo ""
  read -rp "$(echo -e "${YELLOW}确认并开始部署？(y/N)：${NC}")" confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "已取消"; exit 0
  fi
}

# ============================================================
# 保存配置
# ============================================================
save_config() {
  CONFIG_FILE="${INSTALL_DIR}/.aircello-deploy.conf"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<CONF
# Air Cello 部署配置 — 自动生成，请勿手动修改
DOMAIN=${DOMAIN}
GIT_REPO=${GIT_REPO}
GIT_BRANCH=${GIT_BRANCH}
INSTALL_DIR=${INSTALL_DIR}
SSL_EMAIL=${SSL_EMAIL}
DEPLOYED_AT=$(date -Iseconds)
CONF
  chmod 600 "$CONFIG_FILE"
  ok "配置已保存：${CONFIG_FILE}"
}

# ============================================================
# 完整部署流程（首次 & 重新部署共用）
# ============================================================
run_deploy_flow() {
  # ── 1. 系统依赖 ────────────────────────────────────
  step "安装系统依赖"
  apt-get update -qq
  apt-get install -y -qq git curl rsync build-essential > /dev/null 2>&1
  ok "基础工具已就绪"

  # ── 2. Nginx ───────────────────────────────────────
  step "Nginx"
  if command -v nginx &> /dev/null; then
    ok "已安装：$(nginx -v 2>&1)"
  else
    info "安装 Nginx..."
    apt-get install -y -qq nginx > /dev/null 2>&1
    ok "Nginx 安装完成"
  fi
  systemctl enable nginx > /dev/null 2>&1
  systemctl start nginx

  # ── 3. Node.js ─────────────────────────────────────
  step "Node.js"
  local NODE_MAJOR=20
  if command -v node &> /dev/null; then
    ok "已安装：$(node -v)"
  else
    info "安装 Node.js ${NODE_MAJOR}.x LTS..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null 2>&1
    ok "Node.js 安装完成：$(node -v)"
  fi

  # ── 4. Certbot ─────────────────────────────────────
  step "Certbot"
  if command -v certbot &> /dev/null; then
    ok "已安装"
  else
    info "安装 Certbot..."
    apt-get install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1
    ok "Certbot 安装完成"
  fi

  # ── 5. 拉取代码 ────────────────────────────────────
  step "拉取代码"
  local source_dir="${INSTALL_DIR}/source"
  local build_dir="${INSTALL_DIR}/build"
  mkdir -p "$INSTALL_DIR"

  if [[ -d "${source_dir}/.git" ]]; then
    warn "源码目录已存在，拉取最新..."
    cd "$source_dir"
    git fetch origin
    git checkout "$GIT_BRANCH"
    git reset --hard "origin/${GIT_BRANCH}"
  else
    info "Clone 仓库..."
    git clone -b "$GIT_BRANCH" "$GIT_REPO" "$source_dir"
  fi
  cd "$source_dir"
  ok "代码就绪：$(git log --oneline -1)"

  # ── 6. 构建 + 部署产物 ─────────────────────────────
  step "构建项目"
  local detected_build
  detected_build=$(do_build "$source_dir")
  do_deploy_build "$detected_build"

  # ── 7. Nginx 配置 ──────────────────────────────────
  step "配置 Nginx"
  local nginx_conf="/etc/nginx/sites-available/aircello"
  local nginx_link="/etc/nginx/sites-enabled/aircello"

  cat > "$nginx_conf" <<NGINX
# Air Cello — Nginx 配置（由管理脚本自动生成）
# 域名：${DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${build_dir};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "accelerometer=(self), gyroscope=(self)" always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 256;

    access_log /var/log/nginx/aircello.access.log;
    error_log  /var/log/nginx/aircello.error.log;
}
NGINX

  ln -sf "$nginx_conf" "$nginx_link"

  if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
    rm -f /etc/nginx/sites-enabled/default
    warn "已禁用 Nginx 默认站点"
  fi

  nginx -t 2>&1 || err "Nginx 配置语法错误"
  systemctl reload nginx
  ok "Nginx 配置完成"

  # ── 8. SSL ─────────────────────────────────────────
  step "申请 SSL 证书"
  certbot --nginx \
    -d "$DOMAIN" \
    --email "$SSL_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --redirect \
    --non-interactive || {
      warn "SSL 申请失败（DNS 未指向此服务器或 80 端口未开放）"
      warn "可手动补申请：sudo certbot --nginx -d ${DOMAIN}"
    }
  systemctl enable certbot.timer > /dev/null 2>&1 || true
  ok "SSL 配置完成，自动续期已启用"

  # ── 9. 防火墙 ──────────────────────────────────────
  if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow 'Nginx Full' > /dev/null 2>&1
    ok "防火墙已放行 HTTP/HTTPS"
  fi

  # ── 10. 保存配置 ───────────────────────────────────
  save_config

  # ── 完成 ───────────────────────────────────────────
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           🎉  部署完成！               ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  网站地址：  ${GREEN}https://${DOMAIN}${NC}"
  echo -e "  安装目录：  ${INSTALL_DIR}"
  echo -e "  构建目录：  ${INSTALL_DIR}/build"
  echo -e "  Nginx 配置：/etc/nginx/sites-available/aircello"
  echo ""
  echo -e "  ${CYAN}后续管理：${NC}"
  echo -e "  ${YELLOW}sudo ${SCRIPT_PATH} update${NC}   ← 拉取最新更新"
  echo -e "  ${YELLOW}sudo ${SCRIPT_PATH} status${NC}   ← 查看运行状态"
  echo -e "  ${YELLOW}sudo ${SCRIPT_PATH}${NC}          ← 交互菜单"
  echo ""
}

# ============================================================
# 交互菜单
# ============================================================
show_menu() {
  echo -e "  ${BOLD}请选择操作：${NC}"
  sep
  echo -e "  ${CYAN}[1]${NC} 拉取更新      git pull → build → 备份旧版 → 重载 Nginx"
  echo -e "  ${CYAN}[2]${NC} 重新部署      用已有配置完整重走部署流程"
  echo -e "  ${CYAN}[3]${NC} 查看状态      Nginx / SSL / GitHub 新提交"
  echo -e "  ${CYAN}[4]${NC} 查看日志      Nginx 访问 & 错误日志"
  echo -e "  ${CYAN}[5]${NC} 卸载          删证书 + Nginx 配置 + 安装目录"
  echo -e "  ${CYAN}[0]${NC} 退出"
  sep
  echo ""
  read -rp "$(echo -e "${YELLOW}请输入选项 [0-5]：${NC}")" choice
  echo ""

  case "$choice" in
    1) action_update   ;;
    2) action_redeploy ;;
    3) action_status   ;;
    4) action_logs     ;;
    5) action_uninstall;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选项：${choice}"; show_menu ;;
  esac
}

# ============================================================
# 主入口
# ============================================================
CMD="${1:-}"

case "$CMD" in
  update)
    print_banner
    if [[ "$IS_DEPLOYED" == false ]]; then
      err "未找到部署配置，请先运行 sudo ./deploy-aircello.sh 完成首次部署"
    fi
    NON_INTERACTIVE=true
    action_update
    ;;
  status)
    print_banner
    if [[ "$IS_DEPLOYED" == false ]]; then
      err "未找到部署配置"
    fi
    NON_INTERACTIVE=true
    action_status
    ;;
  logs)
    print_banner
    if [[ "$IS_DEPLOYED" == false ]]; then
      err "未找到部署配置"
    fi
    NON_INTERACTIVE=true
    action_logs
    ;;
  "")
    # 交互模式
    print_banner
    if [[ "$IS_DEPLOYED" == true ]]; then
      print_quick_status
      show_menu
    else
      echo -e "  ${YELLOW}未检测到已有部署，开始首次部署向导...${NC}"
      echo ""
      deploy_wizard
      run_deploy_flow
    fi
    ;;
  *)
    echo -e "用法：sudo ./deploy-aircello.sh [update|status|logs]"
    echo -e ""
    echo -e "  （不带参数）  交互菜单 / 首次部署向导"
    echo -e "  update       拉取最新代码并部署"
    echo -e "  status       查看 Nginx / SSL / GitHub 状态"
    echo -e "  logs         查看 Nginx 日志"
    exit 1
    ;;
esac
