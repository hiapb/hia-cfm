#!/usr/bin/env bash

# ==========================================
# CodeFreeMax 生产级运维控制台 (高阶注入版)
# 逻辑：物理文件同步 + 容器内实时 SQL 覆盖
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---- 全局静态配置 ----
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/codefreemax"
COMPOSE_URL="https://raw.githubusercontent.com/ssmDo/CodeFreeMax/main/docker-compose.yml"
CONFIG_URL="https://raw.githubusercontent.com/ssmDo/CodeFreeMax/main/config.yaml"

CRON_TAG_BEGIN="# CODEFREEMAX_BACKUP_BEGIN"
CRON_TAG_END="# CODEFREEMAX_BACKUP_END"
BACKUP_LOG="/var/log/cfm_backup.log"
ENV_RECORD_FILE="/etc/codefreemax_env"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1"
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then echo "docker compose"
    else die "未探测到 Docker Compose 引擎。"; fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

# ---- 核心注入引擎：强行覆盖数据库硬编码值 ----
inject_secure_credentials() {
    local workdir=$1
    local new_pass=$2
    local new_key=$3
    
    info "等待数据库就绪并拦截初始硬编码 (预计 20 秒)..."
    sleep 20
    
    # 物理入侵 MySQL 容器，强制重写 options 表（基于 Kiro 架构的通用 SQL 路由）
    docker exec -i cfm-client-mysql mysql -uroot -pcodefreemax kiro_client -e "
        UPDATE options SET value='${new_pass}' WHERE \`key\`='admin_password';
        UPDATE options SET value='${new_key}' WHERE \`key\`='system_api_key';
    " > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        info "数据库主权接管成功：硬编码弱口令已被物理覆盖。"
    else
        warn "数据库接管失败，请确认数据库是否已完成初始化。您可以稍后通过 [4] 重启尝试自动修复。"
    fi
}

show_credentials() {
    local workdir=$1
    local config_file="${workdir}/config.yaml"
    local env_file="${workdir}/.env"
    
    local sys_admin_pass=$(awk '/^admin:/{flag=1} flag && /password:/{print $2; flag=0}' "$config_file" | tr -d '"' | tr -d "'" | tr -d ' ')
    local sys_api_key=$(awk '/^admin:/{flag=1} flag && /api_key:/{print $2; flag=0}' "$config_file" | tr -d '"' | tr -d "'" | tr -d ' ')
    
    local host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")
    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m✅ CodeFreeMax 实例就绪 (安全密匙已强行对齐)\033[0m"
    echo -e "访问面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "面板密码: \033[31m${sys_admin_pass}\033[0m"
    echo -e "系统 API Key: \033[33m${sys_api_key}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "⚠️  系统已通过 SQL 注入覆盖了作者的硬编码后门。"
    echo -e "==================================================\n"
}

deploy_codefreemax() {
    info "启动部署与数据库注入引擎"
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    require_cmd awk

    local dc_cmd=$(docker_compose_cmd)
    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "路径非空。请先执行 [8] 完全卸载以抹除 MySQL 卷残留。"
        return 
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return

    read -r -p "请输入服务监听端口 [默认: 8877]: " input_port
    local host_port=${input_port:-8877}

    info "同步配置树..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || die "拓扑同步失败"
    curl -sSL "$CONFIG_URL" -o config.yaml || die "配置树同步失败"

    # 生成本次部署的专属随机安全码
    local sys_pass=$(openssl rand -hex 6)
    local sys_key="sk-cfm-$(openssl rand -hex 16)"

    # 同步修改物理文件，保持显示层对齐
    awk -v pw="${sys_pass}" -v ak="${sys_key}" '
        /^admin:/ { in_admin=1; print; next }
        /^[^ ]/ { in_admin=0 }
        in_admin && /password:/ { sub(/password:.*/, "password: \"" pw "\""); print; next }
        in_admin && /api_key:/ { sub(/api_key:.*/, "api_key: \"" ak "\""); print; next }
        { print }
    ' config.yaml > config.yaml.tmp && mv config.yaml.tmp config.yaml

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    mkdir -p data && chmod -R 777 data
    $dc_cmd up -d || die "容器启动失败"

    # 关键步骤：执行数据库强行修正
    inject_secure_credentials "$install_path" "$sys_pass" "$sys_key"
    
    show_credentials "$install_path"
}

upgrade_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" || return
    info "执行无损升级..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    show_credentials "$workdir"
}

pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" && $(docker_compose_cmd) stop
    info "已停止。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" || return
    $(docker_compose_cmd) restart
    
    # 重启时尝试再次同步，防止数据库手动修改导致的不对齐
    local sys_pass=$(awk '/^admin:/{flag=1} flag && /password:/{print $2; flag=0}' config.yaml | tr -d '"' | tr -d "'" | tr -d ' ')
    local sys_key=$(awk '/^admin:/{flag=1} flag && /api_key:/{print $2; flag=0}' config.yaml | tr -d '"' | tr -d "'" | tr -d ' ')
    inject_secure_credentials "$workdir" "$sys_pass" "$sys_key"
    
    show_credentials "$workdir"
}

do_backup() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/cfm_v3_backup_${timestamp}.tar.gz"
    cd "$workdir" && tar -czf "$backup_file" docker-compose.yml config.yaml .env data
    info "备份已存至: ${backup_file}"
}

restore_backup() {
    local workdir=$(get_workdir)
    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup=$(ls -t "${search_dir}"/cfm_v3_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    
    read -r -p "备份路径 [默认: ${default_backup}]: " backup_path
    local path=${backup_path:-$default_backup}
    [[ ! -f "$path" ]] && return
    
    read -r -p "恢复目录 [默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}
    
    mkdir -p "$wd" && tar -xzf "$path" -C "$wd"
    echo "$wd" > "$ENV_RECORD_FILE"
    cd "$wd" && chmod -R 777 data && $(docker_compose_cmd) up -d
    
    show_credentials "$wd"
}

uninstall_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && workdir=$DEFAULT_INSTALL_PATH
    read -r -p "确认彻底卸载并抹除所有数据？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down -v || true
    rm -rf "$workdir" "$ENV_RECORD_FILE"
    info "清理完毕。"
}

install_ftp(){
    info "启动异地备份..."
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "            CodeFreeMax 运维注入控制台             "
    echo "==================================================="
    local wd=$(get_workdir)
    echo -e " 实例路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署 (自动覆盖硬编码后门)"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务 (同步数据库状态)"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载 (核平残留数据)"
    echo "  9) 📂 FTP/SFTP 备份"
    echo "  0) 退出脚本"
    echo "==================================================="
    read -r -p "指令 [0-9]: " choice
    case "$choice" in
        1) deploy_codefreemax ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        0) exit 0 ;;
    esac
}

[[ $EUID -ne 0 ]] && die "需 Root 权限"
while true; do main_menu; echo ""; read -r -p "➤ 回车返回..."; done
