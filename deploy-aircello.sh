#!/usr/bin/env bash
#
# Air Cello — 一键部署脚本
# 适用于 Ubuntu + Nginx，部署纯前端 React 项目
# 支持：自定义安装目录、域名绑定、Let's Encrypt SSL
#
# 用法：
#   chmod +x deploy-aircello.sh
#   sudo ./deploy-aircello.sh
#
set -euo pipefail

# ============================================================
# 颜色输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# Root 权限检查
# ============================================================
if [[ $EUID -ne 0 ]]; then
  err "请使用 sudo 运行此脚本：sudo ./deploy-aircello.sh"
fi

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}   Air Cello 部署脚本 v1.0${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# ============================================================
# 交互式收集配置
# ============================================================

# --- 域名 ---
read -rp "$(echo -e "${YELLOW}请输入域名（如 cello.example.com）：${NC}")" DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "域名不能为空"
fi

# --- Git 仓库 ---
read -rp "$(echo -e "${YELLOW}请输入 Git 仓库地址（HTTPS）：${NC}")" GIT_REPO
if [[ -z "$GIT_REPO" ]]; then
  err "Git 仓库地址不能为空"
fi

# --- Git 分支 ---
read -rp "$(echo -e "${YELLOW}请输入 Git 分支 [main]：${NC}")" GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}

# --- 安装目录 ---
DEFAULT_INSTALL_DIR="/var/www/aircello"
read -rp "$(echo -e "${YELLOW}请输入安装目录 [${DEFAULT_INSTALL_DIR}]：${NC}")" INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}

# --- SSL 邮箱 ---
read -rp "$(echo -e "${YELLOW}请输入 SSL 证书邮箱（Let's Encrypt 通知用）：${NC}")" SSL_EMAIL
if [[ -z "$SSL_EMAIL" ]]; then
  err "邮箱不能为空（Let's Encrypt 要求提供）"
fi

# --- 确认 ---
echo ""
echo -e "${CYAN}─────────── 部署配置确认 ───────────${NC}"
echo -e "  域名：        ${GREEN}${DOMAIN}${NC}"
echo -e "  Git 仓库：    ${GREEN}${GIT_REPO}${NC}"
echo -e "  Git 分支：    ${GREEN}${GIT_BRANCH}${NC}"
echo -e "  安装目录：    ${GREEN}${INSTALL_DIR}${NC}"
echo -e "  SSL 邮箱：    ${GREEN}${SSL_EMAIL}${NC}"
echo -e "${CYAN}────────────────────────────────────${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}确认以上配置？(y/N)：${NC}")" CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  info "已取消部署"
  exit 0
fi

echo ""

# ============================================================
# 保存配置（供后续更新脚本使用）
# ============================================================
CONFIG_FILE="${INSTALL_DIR}/.aircello-deploy.conf"

save_config() {
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
}

# ============================================================
# 1. 系统更新 + 基础依赖
# ============================================================
info "正在更新系统包索引..."
apt-get update -qq

info "正在安装基础依赖（git, curl, rsync, build-essential）..."
apt-get install -y -qq git curl rsync build-essential > /dev/null 2>&1
ok "基础依赖已安装"

# ============================================================
# 2. 安装 / 检查 Nginx
# ============================================================
if command -v nginx &> /dev/null; then
  ok "Nginx 已安装：$(nginx -v 2>&1)"
else
  info "正在安装 Nginx..."
  apt-get install -y -qq nginx > /dev/null 2>&1
  ok "Nginx 已安装"
fi

systemctl enable nginx > /dev/null 2>&1
systemctl start nginx

# ============================================================
# 3. 安装 / 检查 Node.js（使用 NodeSource LTS）
# ============================================================
NODE_MAJOR=20

if command -v node &> /dev/null; then
  CURRENT_NODE=$(node -v)
  ok "Node.js 已安装：${CURRENT_NODE}"
else
  info "正在安装 Node.js ${NODE_MAJOR}.x LTS..."
  # NodeSource 官方安装方式
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  ok "Node.js 已安装：$(node -v)"
fi

# 确保 npm 可用
if ! command -v npm &> /dev/null; then
  err "npm 未找到，请检查 Node.js 安装"
fi

# ============================================================
# 4. 安装 / 检查 Certbot
# ============================================================
if command -v certbot &> /dev/null; then
  ok "Certbot 已安装"
else
  info "正在安装 Certbot..."
  apt-get install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1
  ok "Certbot 已安装"
fi

# ============================================================
# 5. Clone 仓库 + 构建项目
# ============================================================
SOURCE_DIR="${INSTALL_DIR}/source"
BUILD_DIR="${INSTALL_DIR}/build"

if [[ -d "$SOURCE_DIR" ]]; then
  warn "源码目录已存在，正在拉取最新代码..."
  cd "$SOURCE_DIR"
  git fetch origin
  git checkout "$GIT_BRANCH"
  git reset --hard "origin/${GIT_BRANCH}"
else
  info "正在 clone 仓库..."
  mkdir -p "$INSTALL_DIR"
  git clone -b "$GIT_BRANCH" "$GIT_REPO" "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"
ok "代码已就绪：$(git log --oneline -1)"

# --- 构建 ---
if [[ -f "${SOURCE_DIR}/package.json" ]]; then
  # 有 package.json → Node.js 项目，走构建流程
  info "正在安装 npm 依赖..."
  if [[ -f "${SOURCE_DIR}/package-lock.json" ]]; then
    npm ci --prefer-offline --no-audit --no-fund 2>&1 | tail -1
  else
    warn "未找到 package-lock.json，使用 npm install（建议将 lock 文件提交到仓库）"
    npm install --no-audit --no-fund 2>&1 | tail -1
  fi
  ok "依赖安装完成"

  # 检查是否有 build 脚本
  if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)" 2>/dev/null; then
    info "正在构建项目..."
    npm run build 2>&1 | tail -3
  else
    warn "package.json 中未定义 build 脚本，跳过构建步骤"
  fi
fi

# 自动检测构建输出目录（兼容 vite/cra/next）
DETECTED_BUILD=""
for candidate in dist build out .next/static public; do
  if [[ -d "${SOURCE_DIR}/${candidate}" ]]; then
    DETECTED_BUILD="${SOURCE_DIR}/${candidate}"
    break
  fi
done

# 如果没有构建输出目录，检查是否是纯静态项目（根目录有 index.html）
if [[ -z "$DETECTED_BUILD" && -f "${SOURCE_DIR}/index.html" ]]; then
  DETECTED_BUILD="${SOURCE_DIR}"
  info "检测到纯静态项目（根目录 index.html）"
fi

if [[ -z "$DETECTED_BUILD" ]]; then
  err "未找到可部署的文件（尝试了 dist/ build/ out/ public/ 和根目录 index.html），请检查项目结构"
fi

# 复制构建产物到独立的 build 目录
rm -rf "$BUILD_DIR"
if [[ "$DETECTED_BUILD" == "$SOURCE_DIR" ]]; then
  # 纯静态项目：只复制前端文件，排除 .git / node_modules 等
  mkdir -p "$BUILD_DIR"
  rsync -a --exclude='.git' --exclude='node_modules' --exclude='.aircello-deploy.conf' "$SOURCE_DIR/" "$BUILD_DIR/"
else
  cp -r "$DETECTED_BUILD" "$BUILD_DIR"
fi
ok "构建完成：${BUILD_DIR}"

# 设置文件权限
chown -R www-data:www-data "$BUILD_DIR"
chmod -R 755 "$BUILD_DIR"

# ============================================================
# 6. 配置 Nginx
# ============================================================
NGINX_CONF="/etc/nginx/sites-available/aircello"
NGINX_LINK="/etc/nginx/sites-enabled/aircello"

info "正在配置 Nginx..."

cat > "$NGINX_CONF" <<NGINX
# Air Cello — Nginx 配置（由部署脚本自动生成）
# 域名：${DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${BUILD_DIR};
    index index.html;

    # SPA 路由：所有路径回退到 index.html
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 静态资源长缓存（js/css/图片带 hash 的文件）
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # 安全头
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # DeviceMotion API 需要 HTTPS + 权限策略
    add_header Permissions-Policy "accelerometer=(self), gyroscope=(self)" always;

    # Gzip 压缩
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript image/svg+xml;
    gzip_min_length 256;

    access_log /var/log/nginx/aircello.access.log;
    error_log  /var/log/nginx/aircello.error.log;
}
NGINX

# 启用站点配置
ln -sf "$NGINX_CONF" "$NGINX_LINK"

# 移除默认站点（如果存在且会冲突）
if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
  warn "已禁用 Nginx 默认站点配置"
  rm -f /etc/nginx/sites-enabled/default
fi

# 检查 Nginx 配置语法
nginx -t 2>&1 || err "Nginx 配置语法错误，请检查"
systemctl reload nginx
ok "Nginx 配置完成"

# ============================================================
# 7. SSL 证书（Let's Encrypt）
# ============================================================
info "正在申请 SSL 证书..."
echo ""

# certbot 会自动修改 nginx 配置，添加 443 监听和证书路径
certbot --nginx \
  -d "$DOMAIN" \
  --email "$SSL_EMAIL" \
  --agree-tos \
  --no-eff-email \
  --redirect \
  --non-interactive || {
    warn "SSL 证书申请失败！"
    warn "可能原因：域名 DNS 未指向此服务器、80 端口未开放"
    warn "你可以稍后手动运行：certbot --nginx -d ${DOMAIN}"
    warn "HTTP 部署已完成，网站可通过 http://${DOMAIN} 访问"
  }

# 确保 certbot 自动续期生效
systemctl enable certbot.timer > /dev/null 2>&1 || true
ok "SSL 配置完成（自动续期已启用）"

# ============================================================
# 8. 配置防火墙（如果 ufw 已启用）
# ============================================================
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
  info "正在配置防火墙..."
  ufw allow 'Nginx Full' > /dev/null 2>&1
  ok "防火墙已放行 HTTP/HTTPS"
fi

# ============================================================
# 9. 生成更新脚本
# ============================================================
UPDATE_SCRIPT="${INSTALL_DIR}/update-aircello.sh"

cat > "$UPDATE_SCRIPT" <<'UPDATE'
#!/usr/bin/env bash
#
# Air Cello — 更新脚本
# 从 Git 仓库拉取最新代码、重新构建、部署
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  err "请使用 sudo 运行：sudo ./update-aircello.sh"
fi

# 读取部署配置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.aircello-deploy.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  err "找不到部署配置文件：${CONFIG_FILE}\n请先运行 deploy-aircello.sh"
fi

source "$CONFIG_FILE"

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}   Air Cello 更新${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "  域名：${GREEN}${DOMAIN}${NC}"
echo -e "  分支：${GREEN}${GIT_BRANCH}${NC}"
echo ""

SOURCE_DIR="${INSTALL_DIR}/source"
BUILD_DIR="${INSTALL_DIR}/build"

# 允许通过参数切换分支
if [[ $# -ge 1 ]]; then
  GIT_BRANCH="$1"
  info "切换到分支：${GIT_BRANCH}"
fi

# 拉取最新代码
cd "$SOURCE_DIR"
BEFORE=$(git rev-parse --short HEAD)

git fetch origin
git checkout "$GIT_BRANCH"
git reset --hard "origin/${GIT_BRANCH}"

AFTER=$(git rev-parse --short HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
  warn "代码未变化（${BEFORE}），是否仍要重新构建？"
  read -rp "(y/N)：" FORCE
  if [[ "$FORCE" != "y" && "$FORCE" != "Y" ]]; then
    info "已跳过更新"
    exit 0
  fi
fi

info "更新：${BEFORE} → ${AFTER}"
echo -e "  $(git log --oneline -1)"
echo ""

# 构建
if [[ -f "${SOURCE_DIR}/package.json" ]]; then
  info "正在安装依赖..."
  if [[ -f "${SOURCE_DIR}/package-lock.json" ]]; then
    npm ci --prefer-offline --no-audit --no-fund 2>&1 | tail -1
  else
    npm install --no-audit --no-fund 2>&1 | tail -1
  fi

  if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)" 2>/dev/null; then
    info "正在构建..."
    npm run build 2>&1 | tail -3
  fi
fi

# 检测构建目录
DETECTED_BUILD=""
for candidate in dist build out .next/static public; do
  if [[ -d "${SOURCE_DIR}/${candidate}" ]]; then
    DETECTED_BUILD="${SOURCE_DIR}/${candidate}"
    break
  fi
done

if [[ -z "$DETECTED_BUILD" && -f "${SOURCE_DIR}/index.html" ]]; then
  DETECTED_BUILD="${SOURCE_DIR}"
fi

if [[ -z "$DETECTED_BUILD" ]]; then
  err "未找到构建输出目录"
fi

# 备份旧版本
if [[ -d "$BUILD_DIR" ]]; then
  BACKUP="${BUILD_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$BUILD_DIR" "$BACKUP"
  info "旧版本已备份至 ${BACKUP}"
fi

# 部署新版本
if [[ "$DETECTED_BUILD" == "$SOURCE_DIR" ]]; then
  mkdir -p "$BUILD_DIR"
  rsync -a --exclude='.git' --exclude='node_modules' --exclude='.aircello-deploy.conf' "$SOURCE_DIR/" "$BUILD_DIR/"
else
  cp -r "$DETECTED_BUILD" "$BUILD_DIR"
fi
chown -R www-data:www-data "$BUILD_DIR"
chmod -R 755 "$BUILD_DIR"

# 重载 Nginx
nginx -t 2>&1 || err "Nginx 配置异常"
systemctl reload nginx

ok "更新完成！"
echo -e "  版本：${GREEN}${AFTER}${NC}"
echo -e "  地址：${GREEN}https://${DOMAIN}${NC}"
echo ""

# 清理超过 7 天的旧备份
find "$INSTALL_DIR" -maxdepth 1 -name "build.bak.*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
UPDATE

chmod +x "$UPDATE_SCRIPT"
ok "更新脚本已生成：${UPDATE_SCRIPT}"

# ============================================================
# 10. 保存配置
# ============================================================
save_config
ok "部署配置已保存：${CONFIG_FILE}"

# ============================================================
# 完成
# ============================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}   部署完成！${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "  网站地址：    ${GREEN}https://${DOMAIN}${NC}"
echo -e "  安装目录：    ${INSTALL_DIR}"
echo -e "  源码目录：    ${INSTALL_DIR}/source"
echo -e "  构建目录：    ${INSTALL_DIR}/build"
echo -e "  Nginx 配置：  ${NGINX_CONF}"
echo -e "  部署配置：    ${CONFIG_FILE}"
echo ""
echo -e "  ${CYAN}后续更新：${NC}"
echo -e "  ${YELLOW}sudo ${UPDATE_SCRIPT}${NC}"
echo -e "  ${YELLOW}sudo ${UPDATE_SCRIPT} feature-branch${NC}  ← 切换分支"
echo ""
echo -e "  ${CYAN}常用命令：${NC}"
echo -e "  查看日志：tail -f /var/log/nginx/aircello.access.log"
echo -e "  SSL 续期：sudo certbot renew --dry-run"
echo -e "  重启服务：sudo systemctl restart nginx"
echo ""
