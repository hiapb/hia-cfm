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

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺失核心依赖: $1"; }
get_local_ip() { hostname -I | awk '{print $1}' || echo "127.0.0.1"; }

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then echo "docker compose"
    else die "未探测到 Docker Compose 引擎。"; fi
}

get_workdir() {
    if [[ -f "$ENV_RECORD_FILE" ]]; then
        local dir=$(cat "$ENV_RECORD_FILE")
        if [[ -d "$dir" ]]; then echo "$dir"; return; fi
    fi
    echo ""
}

extract_and_show_credentials() {
    local workdir=$1
    local config_file="${workdir}/config.yaml"
    local env_file="${workdir}/.env"
    
    if [[ ! -f "$config_file" ]]; then return; fi
    
    # 利用边界定位符精准提取，彻底无视格式变异
    local sys_admin_pass=$(awk '/^admin:/{flag=1} flag && /password:/{print $2; flag=0}' "$config_file" | tr -d ' "\'')
    local sys_api_key=$(awk '/^admin:/{flag=1} flag && /api_key:/{print $2; flag=0}' "$config_file" | tr -d ' "\'')
    
    local host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")
    local server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m✅ CodeFreeMax 实例就绪\033[0m"
    echo -e "控制面板: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "面板密码: \033[31m${sys_admin_pass:-[解析失败]}\033[0m"
    echo -e "系统 API Key: \033[33m${sys_api_key:-[解析失败]}\033[0m"
    echo -e "--------------------------------------------------"
    echo -e "配置根源: \033[33m${config_file}\033[0m"
    echo -e "==================================================\n"
}

deploy_codefreemax() {
    info "启动部署引擎"
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    require_cmd sed
    require_cmd awk
    
    local dc_cmd=$(docker_compose_cmd)
    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "检测到存量实例。请先执行 [8] 完全卸载以抹除数据库残留。"
        return 
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return

    read -r -p "请输入服务监听端口 [默认: 8877]: " input_port
    local host_port=${input_port:-8877}

    info "拉取远程拓扑与配置树..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || { err "拓扑同步失败。"; return; }
    curl -sSL "$CONFIG_URL" -o config.yaml || { err "配置树同步失败。"; return; }

    local new_admin_pass=$(openssl rand -hex 6)
    local new_api_key="sk-cfm-$(openssl rand -hex 16)"

    info "执行高能态正则注入，切断上游预设钩子..."
    # 采用 awk 跨平台绝对替换，锁定 admin 节点级，无视原值是 sk-paas 还是空白
    awk -v pw="${new_admin_pass}" -v ak="${new_api_key}" '
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
    $dc_cmd up -d || { err "容器启动异常。"; return; }

    extract_and_show_credentials "$install_path"
}

upgrade_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未发现实例。"; return; }
    cd "$workdir" || return
    info "执行无损滚动升级..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    extract_and_show_credentials "$workdir"
}

pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" && $(docker_compose_cmd) stop
    info "服务已静默。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    cd "$workdir" && $(docker_compose_cmd) restart
    info "服务已重启。"
}

do_backup() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/cfm_v3_backup_${timestamp}.tar.gz"
    
    cd "$workdir" || return
    local target_files=$(ls -A | grep -E 'docker-compose\.yml|config\.yaml|\.env|data' || true)
    [[ -z "$target_files" ]] && return
    
    tar -czf "$backup_file" $target_files
    cd "$backup_dir" && ls -t cfm_v3_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    info "快照就绪: ${backup_file}"
}

restore_backup() {
    local workdir=$(get_workdir)
    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    local default_backup=$(ls -t "${search_dir}"/cfm_v3_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    
    if [[ -n "$default_backup" ]]; then
        read -r -p "嗅探到快照 [${default_backup}]，直接回车使用: " input_backup
        local backup_path=${input_backup:-$default_backup}
    else
        read -r -p "输入快照绝对路径: " backup_path
    fi
    [[ ! -f "$backup_path" ]] && { err "无效路径。"; return; }
    
    read -r -p "恢复至目录 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$target_dir" ]]; then
        read -r -p "将覆盖存量数据，是否继续？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
        cd "$target_dir" && $(docker_compose_cmd) down || true
    fi
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir"
    echo "$target_dir" > "$ENV_RECORD_FILE"
    cd "$target_dir" && chmod -R 777 data && $(docker_compose_cmd) up -d
    
    extract_and_show_credentials "$target_dir"
}

setup_auto_backup() {
    require_cmd crontab
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    
    local cron_script="${workdir}/cfm_auto_cron.sh"
    echo " 1) 每小时备份"
    echo " 2) 每日 03:00 备份"
    echo " 3) 移除定时任务"
    read -r -p "选择策略 [1/2/3]: " cron_type

    local cron_spec=""
    case "$cron_type" in
        1) cron_spec="0 * * * *" ;;
        2) cron_spec="0 3 * * *" ;;
        3) 
            crontab -l | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
            rm -f "$cron_script"
            info "定时任务已注销。"
            return 
            ;;
        *) return ;;
    esac

    cat > "$cron_script" << EOF
#!/usr/bin/env bash
cd "${workdir}"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
tar -czf "backups/cfm_v3_backup_\${TIMESTAMP}.tar.gz" docker-compose.yml config.yaml .env data
cd backups && ls -t cfm_v3_backup_*.tar.gz | awk 'NR>5' | xargs -I {} rm -f {}
EOF
    chmod +x "$cron_script"

    (crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"; echo -e "${CRON_TAG_BEGIN}\n${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1\n${CRON_TAG_END}") | crontab -
    info "调度器已更新。"
}

uninstall_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && return
    
    read -r -p "确认物理销毁实例与数据？[y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    cd "$workdir" && $(docker_compose_cmd) down -v || true
    rm -rf "$workdir" "$ENV_RECORD_FILE"
    crontab -l | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
    info "资源已深度释放。"
}

install_ftp(){
    clear
    info "启动 FTP/SFTP 同步挂载..."
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    exit 0
}

main_menu() {
    clear
    echo "==================================================="
    echo "                 CodeFreeMax 管理  1                "
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
        0) exit 0 ;;
        *) warn "无效输入" ;;
    esac
}

if [[ $EUID -ne 0 ]]; then die "请使用 Root 权限执行。"; fi
while true; do
    main_menu
    echo ""
    read -r -p "➤ 按回车键返回主菜单..."
done
