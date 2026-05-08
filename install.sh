#!/usr/bin/env bash

set -e

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

DEFAULT_INSTALL_PATH="/opt/codefreemax"

COMPOSE_URL="https://raw.githubusercontent.com/ssmDo/CodeFreeMax/main/docker-compose.yml"
CONFIG_URL="https://raw.githubusercontent.com/ssmDo/CodeFreeMax/main/config.yaml"

CRON_TAG_BEGIN="# CODEFREEMAX_BACKUP_BEGIN"
CRON_TAG_END="# CODEFREEMAX_BACKUP_END"

BACKUP_LOG="/var/log/cfm_backup.log"
ENV_RECORD_FILE="/etc/codefreemax_env"

MYSQL_CONTAINER="cfm-client-mysql"
MYSQL_DB="kiro_client"
MYSQL_USER="root"
MYSQL_PASS="codefreemax"

REDIS_CONTAINER="cfm-client-redis"

info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"
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
        die "未检测到 Docker Compose"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

wait_mysql_ready() {
    info "等待 MySQL 初始化..."

    for i in {1..60}; do
        if docker exec "$MYSQL_CONTAINER" mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASS" >/dev/null 2>&1; then
            info "MySQL 已就绪"
            return 0
        fi
        sleep 2
    done

    return 1
}

generate_credentials() {
    SYS_PASS=$(openssl rand -hex 6)
    SYS_KEY="sk-cfm-$(openssl rand -hex 16)"
}

write_config_credentials() {
    local config_file="$1"

    sed -i -E "s|(password:).*|\1 \"${SYS_PASS}\"|g" "$config_file"
    sed -i -E "s|(api_key:).*|\1 \"${SYS_KEY}\"|g" "$config_file"
}

inject_db_credentials() {

    info "正在同步密码/APIKey 到数据库..."

    docker exec -i "$MYSQL_CONTAINER" mysql \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        "$MYSQL_DB" <<EOF

UPDATE system_configs
SET value='${SYS_PASS}'
WHERE \`key\` IN ('admin_password','password');

UPDATE system_configs
SET value='${SYS_KEY}'
WHERE \`key\` IN ('system_api_key','api_key');

UPDATE system_configs
SET \`value\`='${SYS_PASS}'
WHERE \`name\` IN ('admin_password','password');

UPDATE system_configs
SET \`value\`='${SYS_KEY}'
WHERE \`name\` IN ('system_api_key','api_key');

EOF

    info "数据库凭据同步完成"
}

show_credentials() {

    local workdir="$1"
    local env_file="${workdir}/.env"

    local host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")

    echo ""
    echo "=================================================="
    echo -e "\033[32mCodeFreeMax 部署完成\033[0m"
    echo "--------------------------------------------------"
    echo -e "访问地址: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "--------------------------------------------------"
    echo -e "管理员密码: \033[31m${SYS_PASS}\033[0m"
    echo -e "API Key: \033[33m${SYS_KEY}\033[0m"
    echo "=================================================="
    echo ""
}

deploy_codefreemax() {

    require_cmd docker
    require_cmd curl
    require_cmd openssl
    require_cmd tar

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "安装目录 [默认: ${DEFAULT_INSTALL_PATH}]: " input_path

    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        die "目录非空: ${install_path}"
    fi

    mkdir -p "$install_path"

    echo "$install_path" > "$ENV_RECORD_FILE"

    cd "$install_path"

    read -r -p "访问端口 [默认: 8877]: " input_port

    local host_port=${input_port:-8877}

    info "下载配置文件..."

    curl -sSL "$COMPOSE_URL" -o docker-compose.yml
    curl -sSL "$CONFIG_URL" -o config.yaml

    generate_credentials

    write_config_credentials "config.yaml"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    mkdir -p data

    chmod -R 777 data

    info "启动容器..."

    $dc_cmd up -d

    wait_mysql_ready || die "MySQL 初始化失败"

    sleep 8

    inject_db_credentials || warn "数据库注入失败"

    show_credentials "$install_path"
}

upgrade_service() {

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署"

    cd "$workdir"

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "拉取最新镜像..."

    $dc_cmd pull

    $dc_cmd up -d

    wait_mysql_ready || true

    inject_db_credentials || true

    show_credentials "$workdir"
}

pause_service() {

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署"

    cd "$workdir"

    $(docker_compose_cmd) stop

    info "服务已停止"
}

restart_service() {

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署"

    cd "$workdir"

    $(docker_compose_cmd) restart

    wait_mysql_ready || true

    inject_db_credentials || true

    show_credentials "$workdir"
}

do_backup() {

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署"

    local backup_dir="${workdir}/backups"

    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local temp_dir="${backup_dir}/tmp_${timestamp}"

    mkdir -p "$temp_dir"

    info "导出 MySQL..."

    docker exec "$MYSQL_CONTAINER" mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        --single-transaction \
        --routines \
        --triggers \
        "$MYSQL_DB" > "${temp_dir}/mysql.sql"

    info "导出 Redis..."

    docker exec "$REDIS_CONTAINER" redis-cli SAVE >/dev/null 2>&1 || true

    docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "${temp_dir}/dump.rdb" >/dev/null 2>&1 || true

    cp "${workdir}/docker-compose.yml" "${temp_dir}/"
    cp "${workdir}/config.yaml" "${temp_dir}/"
    cp "${workdir}/.env" "${temp_dir}/"

    if [[ -d "${workdir}/data" ]]; then
        cp -r "${workdir}/data" "${temp_dir}/"
    fi

    local backup_file="${backup_dir}/cfm_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .

    rm -rf "$temp_dir"

    cd "$backup_dir"

    ls -t cfm_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {

    local workdir
    workdir=$(get_workdir)

    local backup_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"

    local latest_backup
    latest_backup=$(ls -t "${backup_dir}"/cfm_backup_*.tar.gz 2>/dev/null | head -n 1)

    read -r -p "备份文件路径 [默认: ${latest_backup}]: " backup_path

    local path=${backup_path:-$latest_backup}

    [[ ! -f "$path" ]] && die "备份文件不存在"

    read -r -p "恢复目录 [默认: ${DEFAULT_INSTALL_PATH}]: " target_dir

    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$wd" ]]; then

        read -r -p "目录已存在，强制覆盖？(y/N): " confirm

        [[ ! "$confirm" =~ ^[Yy]$ ]] && return

        cd "$wd" 2>/dev/null || true

        $(docker_compose_cmd) down -v || true
    fi

    mkdir -p "$wd"

    tar -xzf "$path" -C "$wd"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd"

    chmod -R 777 data 2>/dev/null || true

    info "启动恢复后的容器..."

    $(docker_compose_cmd) up -d

    wait_mysql_ready || die "MySQL 启动失败"

    sleep 5

    if [[ -f "${wd}/mysql.sql" ]]; then

        info "恢复 MySQL 数据..."

        docker exec -i "$MYSQL_CONTAINER" mysql \
            -u"$MYSQL_USER" \
            -p"$MYSQL_PASS" \
            "$MYSQL_DB" < "${wd}/mysql.sql"

    else
        warn "未找到 mysql.sql"
    fi

    if [[ -f "${wd}/dump.rdb" ]]; then

        info "恢复 Redis 数据..."

        docker cp "${wd}/dump.rdb" "${REDIS_CONTAINER}:/data/dump.rdb" >/dev/null 2>&1 || true

        docker restart "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    fi

    show_credentials "$wd"
}

setup_auto_backup() {

    require_cmd crontab

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署"

    local cron_script="${workdir}/cron_backup.sh"

    echo "1) 每隔 X 分钟"
    echo "2) 每天固定时间"
    echo "3) 删除定时任务"

    read -r -p "请选择: " cron_type

    local cron_spec=""

    case "$cron_type" in

        1)
            read -r -p "分钟间隔: " min_interval
            cron_spec="*/${min_interval} * * * *"
        ;;

        2)
            read -r -p "时间 (HH:MM): " cron_time

            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"

            cron_spec="${minute} ${hour} * * *"
        ;;

        3)

            crontab -l 2>/dev/null | \
            sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | \
            crontab -

            rm -f "$cron_script"

            info "定时任务已删除"

            return
        ;;

        *)
            die "无效选项"
        ;;

    esac

    cat > "$cron_script" <<EOF
#!/usr/bin/env bash
bash ${SCRIPT_PATH} run-backup >> ${BACKUP_LOG} 2>&1
EOF

    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | \
        sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"

        echo "${CRON_TAG_BEGIN}"
        echo "${cron_spec} bash ${cron_script}"
        echo "${CRON_TAG_END}"

    ) | crontab -

    info "定时备份已设置"
}

uninstall_service() {

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo ""
    echo -e "\033[31m警告: 将彻底删除所有数据\033[0m"
    echo ""

    read -r -p "确认卸载？(y/N): " confirm

    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then

        cd "$workdir" 2>/dev/null || true

        $(docker_compose_cmd) down -v || true

        cd /

        rm -rf "$workdir"
    fi

    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | \
    sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | \
    crontab -

    info "已彻底卸载"
}

main_menu() {

    clear

    local wd
    wd=$(get_workdir)

    echo "==================================================="
    echo "              CodeFreeMax 管理脚本"
    echo "==================================================="
    echo "安装目录: ${wd:-未部署}"
    echo "---------------------------------------------------"
    echo "1) 一键部署"
    echo "2) 升级服务"
    echo "3) 停止服务"
    echo "4) 重启服务"
    echo "5) 手动备份"
    echo "6) 恢复备份"
    echo "7) 定时备份"
    echo "8) 完全卸载"
    echo "0) 退出"
    echo "==================================================="

    read -r -p "请输入选项: " choice

    case "$choice" in

        1) deploy_codefreemax ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        0) exit 0 ;;

        *)
            warn "无效选项"
        ;;

    esac
}

if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else

    [[ $EUID -ne 0 ]] && die "请使用 root 权限运行"

    while true; do
        main_menu
        echo ""
        read -r -p "按回车继续..."
    done
fi
