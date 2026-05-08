#!/usr/bin/env bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
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

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1"; }
get_local_ip() { hostname -I | awk '{print $1}' || echo "127.0.0.1"; }

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then echo "docker compose"
    else die "未探测到 Docker Compose 引擎。"; fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

inject_secure_credentials() {
    local workdir=$1
    local new_pass=$2
    local new_key=$3
    info "正在拦截初始化硬编码注入 (预计需等待 20 秒)..."
    sleep 20
    docker exec -i cfm-client-mysql mysql -uroot -pcodefreemax kiro_client -e "
        UPDATE options SET value='${new_pass}' WHERE \`key\`='admin_password';
        UPDATE options SET value='${new_key}' WHERE \`key\`='system_api_key';
    " > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        info "数据库主权接管成功：系统后门已被物理覆盖。"
    else
        warn "数据库接管失败，可能初始化未完成，请稍后通过面板手动修改。"
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
    echo -e "\033[32m✅ CodeFreeMax 实例就绪\033[0m"
    echo -e "控制面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "面板密码: \033[31m${sys_admin_pass}\033[0m"
    echo -e "系统 API Key: \033[33m${sys_api_key}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "⚠️ 系统已强制执行 SQL 注入，接管了初始鉴权凭证。"
    echo -e "==================================================\n"
}

deploy_codefreemax() {
    info "== 启动 CodeFreeMax 自动化部署编排 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    require_cmd awk
    local dc_cmd=$(docker_compose_cmd)
    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        err "该路径已存在部署实例或残留数据，请先执行 [8] 卸载。"
        return 
    fi
    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return
    read -r -p "请输入对外访问端口 [默认: 8877]: " input_port
    local host_port=${input_port:-8877}
    info "正在拉取核心拓扑文件..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || die "拓扑同步失败"
    curl -sSL "$CONFIG_URL" -o config.yaml || die "配置树同步失败"
    local sys_pass=$(openssl rand -hex 6)
    local sys_key="sk-cfm-$(openssl rand -hex 16)"
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
    info "正在拉起微服务矩阵..."
    $dc_cmd up -d || die "容器启动失败"
    inject_secure_credentials "$install_path" "$sys_pass" "$sys_key"
    show_credentials "$install_path"
}

upgrade_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到运行中的网关，请先执行 [1] 一键部署。"; return; }
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    show_credentials "$workdir"
}

pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到部署环境。"; return; }
    cd "$workdir" && $(docker_compose_cmd) stop
    info "服务已停止。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到部署环境。"; return; }
    cd "$workdir" || return
    $(docker_compose_cmd) restart
    local sys_pass=$(awk '/^admin:/{flag=1} flag && /password:/{print $2; flag=0}' config.yaml | tr -d '"' | tr -d "'" | tr -d ' ')
    local sys_key=$(awk '/^admin:/{flag=1} flag && /api_key:/{print $2; flag=0}' config.yaml | tr -d '"' | tr -d "'" | tr -d ' ')
    inject_secure_credentials "$workdir" "$sys_pass" "$sys_key"
    show_credentials "$workdir"
}

do_backup() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到部署环境。"; return; }
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/cfm_backup_${timestamp}.tar.gz"
    cd "$workdir" && tar -czf "$backup_file" docker-compose.yml config.yaml .env data 2>/dev/null
    cd "$backup_dir" && ls -t cfm_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    info "备份执行完毕。当前可用备份如下: ${backup_file}"
}

restore_backup() {
    local workdir=$(get_workdir)
    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup=$(ls -t "${search_dir}"/cfm_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    read -r -p "请输入备份文件路径 [直接回车使用默认: ${default_backup}]: " backup_path
    local path=${backup_path:-$default_backup}
    [[ ! -f "$path" ]] && { err "未找到有效的快照文件。"; return; }
    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}
    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在实例，是否强制覆盖？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
        cd "$wd" && $(docker_compose_cmd) down || true
    fi
    mkdir -p "$wd" && tar -xzf "$path" -C "$wd"
    echo "$wd" > "$ENV_RECORD_FILE"
    cd "$wd" && chmod -R 777 data && $(docker_compose_cmd) up -d
    show_credentials "$wd"
}

setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到部署环境。"; return; }
    local cron_script="${workdir}/cron_backup.sh"
    echo " 1) 按固定分钟步进备份（推荐：1/2/3/4/5/6/10/12/15/20/30）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type
    local cron_spec=""
    case "$cron_type" in
        1) 
            read -r -p "请输入间隔分钟数: " min_interval
            cron_spec="*/${min_interval} * * * *" 
            ;;
        2) 
            read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            cron_spec="${minute} ${hour} * * *" 
            ;;
        3) 
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
            rm -f "$cron_script"
            info "定时任务已注销。"
            return 
            ;;
        *) err "无效选择"; return ;;
    esac
    cat > "$cron_script" << EOF
#!/usr/bin/env bash
cd "${workdir}"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
tar -czf "backups/cfm_backup_\${TIMESTAMP}.tar.gz" docker-compose.yml config.yaml .env data 2>/dev/null
cd backups && ls -t cfm_backup_*.tar.gz | awk 'NR>3' | xargs -I {} rm -f {}
EOF
    chmod +x "$cron_script"
    (crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"; echo -e "${CRON_TAG_BEGIN}\n${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1\n${CRON_TAG_END}") | crontab -
    info "新的定时任务已注入。"
}

uninstall_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && workdir=$DEFAULT_INSTALL_PATH
    echo -e "\033[31m⚠️ 警告：这将彻底摧毁所有容器及业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down -v || true
        cd /
        rm -rf "$workdir"
    fi
    rm -f "$ENV_RECORD_FILE"
    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
    info "容器及业务数据已被安全抹除。"
}

install_ftp(){
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "                 CodeFreeMax 一键管理              "
    echo "==================================================="
    local wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo "  0) 退出脚本"
    echo "==================================================="
    read -r -p "请输入操作序号 [0-9]: " choice
    case "$choice" in
        1) deploy_codefreemax ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        0) info "欢迎下次使用，再见!"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限收敛：必须使用 Root 权限执行脚本。"; fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
