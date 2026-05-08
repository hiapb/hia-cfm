#!/usr/bin/env bash

# ==========================================
# CodeFreeMax 生产级运维控制台 (v3.0.0+)
# 秘书风格维护 | 高逻辑密度 | 深度故障隔离
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

# ---- 基础防御性函数 ----
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺失系统级依赖: $1。请执行 apt/yum install $1 后重试。"
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未探测到 Docker Compose。建议安装 Docker Desktop 或 Docker-CE 插件。"
    fi
}

get_workdir() {
    if [[ -f "$ENV_RECORD_FILE" ]]; then
        local dir=$(cat "$ENV_RECORD_FILE")
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

# ---- 1. 一键部署系统 (PaaS 架构适配版) ----
deploy_codefreemax() {
    info "== 启动 CodeFreeMax 自动化编排流程 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl
    
    local dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$install_path" && -f "$install_path/docker-compose.yml" ]]; then
        err "该路径已存在运行中的实例，请先执行 [8] 卸载或直接执行 [2] 升级。"
        return 
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"
    cd "$install_path" || return

    read -r -p "请输入服务监听端口 [默认: 8877]: " input_port
    local host_port=${input_port:-8877}

    info "正在从 GitHub 镜像源同步拓扑文件与业务配置..."
    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || { err "拓扑文件同步失败。"; return; }
    curl -sSL "$CONFIG_URL" -o config.yaml || { err "业务配置文件同步失败。"; return; }

    # 注入环境变量，确保 Docker Compose 能正确映射端口
    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
# 系统随机生成的混淆密钥
DB_PASSWORD=$(openssl rand -hex 16)
EOF

    # 预建物理卷目录并强制提权，防止 MySQL/Redis 容器因权限锁死
    mkdir -p data
    chmod -R 777 data

    info "拉起微服务矩阵 (MySQL/Redis/App)..."
    $dc_cmd up -d || { err "容器矩阵启动失败，请检查端口 ${host_port} 是否被占用。"; return; }

    local server_ip=$(get_local_ip)
    echo -e "\n=================================================="
    echo -e "\033[32m✅ CodeFreeMax 部署指令执行成功！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "配置文件: \033[33m${install_path}/config.yaml\033[0m"
    echo -e "注: 请根据实际需求修改 config.yaml 中的 Upstream 秘钥。"
    echo -e "==================================================\n"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未发现有效的部署环境。"
        return
    fi
    cd "$workdir" || return
    info "正在拉取最新镜像版本并执行滚动更新..."
    $(docker_compose_cmd) pull
    $(docker_compose_cmd) up -d
    info "服务已完成热重载。"
}

# ---- 3/4. 状态控制 ----
pause_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未部署。"; return; }
    cd "$workdir" && $(docker_compose_cmd) stop
    info "微服务已进入挂起状态。"
}

restart_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "未部署。"; return; }
    cd "$workdir" && $(docker_compose_cmd) restart
    info "微服务已完成重启。"
}

# ---- 5. 手动备份 ----
do_backup() {
    local workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "无可用环境执行备份。"
        return
    fi
    
    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_dir}/cfm_v3_backup_${timestamp}.tar.gz"
    
    info "锁定数据快照中..."
    cd "$workdir" || return
    
    # 针对 v3 版本核心文件进行打包
    local target_files=$(ls -A | grep -E 'docker-compose\.yml|config\.yaml|\.env|data' || true)
    if [[ -z "$target_files" ]]; then
        err "核心资产为空，备份终止。"; return
    fi
    
    tar -czf "$backup_file" $target_files
    
    # 轮转策略：保留最近 3 份冷备份
    cd "$backup_dir" && ls -t cfm_v3_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
    
    info "备份完成。快照已存至: \033[36m${backup_file}\033[0m"
}

# ---- 6. 恢复备份 ----
restore_backup() {
    info "== 启动灾备恢复引擎 =="
    local workdir=$(get_workdir)
    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"
    
    local default_backup=$(ls -t "${search_dir}"/cfm_v3_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    
    if [[ -n "$default_backup" ]]; then
        echo -e "嗅探到最新快照: \033[33m${default_backup}\033[0m"
        read -r -p "输入路径 [直接回车使用最新]: " input_backup
        local backup_path=${input_backup:-$default_backup}
    else
        read -r -p "请输入备份文件(.tar.gz)绝对路径: " backup_path
    fi
    
    [[ ! -f "$backup_path" ]] && { err "快照文件不存在。"; return; }
    
    read -r -p "恢复至目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}
    
    if [[ -d "$target_dir" ]]; then
        warn "检测到存量数据，恢复将执行覆盖操作！"
        read -r -p "确认覆盖？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
        cd "$target_dir" && $(docker_compose_cmd) down || true
    fi
    
    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir"
    echo "$target_dir" > "$ENV_RECORD_FILE"
    cd "$target_dir" && chmod -R 777 data && $(docker_compose_cmd) up -d
    info "数据接管成功，业务已恢复。"
}

# ---- 7. 自动化定时任务 ----
setup_auto_backup() {
    require_cmd crontab
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "环境未就绪。"; return; }
    
    local cron_script="${workdir}/cfm_auto_cron.sh"
    
    echo " 1) 每小时备份"
    echo " 2) 每日凌晨 03:00 备份"
    echo " 3) 移除自动化任务"
    read -r -p "选择调度策略 [1/2/3]: " cron_type

    local cron_spec=""
    case "$cron_type" in
        1) cron_spec="0 * * * *" ;;
        2) cron_spec="0 3 * * *" ;;
        3) 
            crontab -l | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
            rm -f "$cron_script"
            info "自动化任务已下线。"
            return 
            ;;
        *) err "未知策略。"; return ;;
    esac

    # 生成物理执行脚本
    cat > "$cron_script" << EOF
#!/usr/bin/env bash
cd "${workdir}"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
tar -czf "backups/cfm_v3_backup_\${TIMESTAMP}.tar.gz" docker-compose.yml config.yaml .env data
cd backups && ls -t cfm_v3_backup_*.tar.gz | awk 'NR>5' | xargs -I {} rm -f {}
EOF
    chmod +x "$cron_script"

    # 注入 Crontab
    (crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"; echo -e "${CRON_TAG_BEGIN}\n${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1\n${CRON_TAG_END}") | crontab -
    info "时钟守护进程已锁定，策略已生效。"
}

# ---- 8. 彻底卸载 ----
uninstall_service() {
    local workdir=$(get_workdir)
    [[ -z "$workdir" ]] && { err "无环境可卸载。"; return; }
    
    warn "该操作将物理抹除所有数据库数据与配置文件！"
    read -r -p "输入确认字符 [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    cd "$workdir" && $(docker_compose_cmd) down -v || true
    rm -rf "$workdir" "$ENV_RECORD_FILE"
    crontab -l | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
    info "已完成深度清理。"
}

install_ftp(){
    clear
    info "📂 启动异地 FTP/SFTP 容灾同步中枢..."
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    exit 0
}

# ---- 交互式主菜单 ----
main_menu() {
    clear
    echo "==================================================="
    echo "          CodeFreeMax (v3) 生产环境控制台         "
    echo "==================================================="
    local wd=$(get_workdir)
    echo -e " 运行时根路径: \033[36m${wd:-未探测到活动实例}\033[0m"
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
    
    read -r -p "系统等待指令 [0-9]: " choice
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
        *) warn "非法指令协议。" ;;
    esac
}

# 引导加载
if [[ $EUID -ne 0 ]]; then die "本控制台需要物理级 Root 权限。"; fi
while true; do
    main_menu
    echo ""
    read -r -p "➤ 按回车键返回主菜单..."
done
