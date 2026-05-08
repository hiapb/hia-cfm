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

show_credentials() {
    local workdir=$1
    local env_file="${workdir}/.env"
    local host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")
    local server_ip=$(get_local_ip)
    
    echo -e "\n=================================================="
    echo -e "\033[32m✅ CodeFreeMax 实例部署就绪\033[0m"
    echo -e "控制面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "【系统出厂默认鉴权凭证】"
    echo -e "默认面板密码: \033[31madmin123\033[0m"
    echo -e "默认 API Key: \033[33msk-paas\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "⚠️ 安全警示：出厂口令已锁定在数据库中。"
    echo -e "⚠️ 登入后，请务必立即在【系统配置】修改您的密码与密钥！"
    echo -e "==================================================\n"
}

deploy_codefreemax() {
    info "== 启动 CodeFreeMax 极简部署编排 =="
    require_cmd docker
    require_cmd curl
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
    
    info "正在拉取核心拓扑与配置..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || die "拓扑同步失败"
    curl -sSL "$CONFIG_URL" -o config.yaml || die "配置树同步失败"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF
    mkdir -p data && chmod -R 777 data
    
    info "正在拉起微服务矩阵 (初次运行需耗时建立数据库)..."
    $dc_cmd up -d || die "容器启动失败"
    
    show_credentials "$install_path"
}

upgrade_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未检测到运行中的网关，请先执行 [1] 一键部署。"; return; }
    cd "$workdir" || return
    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    info "更新完成。"
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
    info "服务已重启。"
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
    info "恢复完成。"
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
