#!/usr/bin/env bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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

generate_credentials() {
    SYS_PASS=$(openssl rand -hex 6)
    SYS_KEY="sk-cfm-$(openssl rand -hex 16)"
}

read_credentials_from_config() {
    local config_file="$1"

    SYS_PASS=$(awk '
        /^admin:/ { in_admin=1; next }
        /^[a-zA-Z0-9_-]+:/ { in_admin=0 }
        in_admin && /^[[:space:]]*password:/ {
            gsub(/["'\'' ]/, "", $2)
            print $2
            exit
        }
    ' "$config_file")

    SYS_KEY=$(awk '
        /^admin:/ { in_admin=1; next }
        /^[a-zA-Z0-9_-]+:/ { in_admin=0 }
        in_admin && /^[[:space:]]*api_key:/ {
            gsub(/["'\'' ]/, "", $2)
            print $2
            exit
        }
    ' "$config_file")
}

write_config_credentials() {
    local config_file="$1"

    awk -v pw="$SYS_PASS" -v ak="$SYS_KEY" '
        /^admin:/ {
            in_admin=1
            print
            next
        }

        /^[a-zA-Z0-9_-]+:/ {
            if ($0 !~ /^admin:/) in_admin=0
        }

        in_admin && /^[[:space:]]*password:/ {
            sub(/password:.*/, "password: \"" pw "\"")
            print
            next
        }

        in_admin && /^[[:space:]]*api_key:/ {
            sub(/api_key:.*/, "api_key: \"" ak "\"")
            print
            next
        }

        { print }
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
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

wait_app_ready() {
    info "等待 CodeFreeMax 初始化..."

    for i in {1..60}; do
        if docker ps --format '{{.Names}} {{.Status}}' | grep -q '^codefreemax .*Up'; then
            return 0
        fi
        sleep 2
    done

    warn "CodeFreeMax 可能未正常启动"
    return 1
}

inject_db_credentials() {
    info "等待业务配置表初始化..."

    local table=""

    for i in {1..60}; do
        table=$(docker exec "$MYSQL_CONTAINER" mysql \
            -u"$MYSQL_USER" \
            -p"$MYSQL_PASS" \
            -N -B "$MYSQL_DB" \
            -e "SHOW TABLES LIKE '%config%';" 2>/dev/null | head -n 1 || true)

        [[ -n "$table" ]] && break

        sleep 2
    done

    if [[ -z "$table" ]]; then
        warn "未检测到配置表，跳过数据库凭据同步"
        return 1
    fi

    info "检测到配置表: $table"
    info "同步密码/API Key 到数据库..."

    docker exec -i "$MYSQL_CONTAINER" mysql \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        "$MYSQL_DB" <<EOF
UPDATE \`${table}\`
SET value='${SYS_PASS}'
WHERE \`key\` IN ('admin_password','password','system_password');

UPDATE \`${table}\`
SET value='${SYS_KEY}'
WHERE \`key\` IN ('system_api_key','api_key','apikey');

UPDATE \`${table}\`
SET value='${SYS_PASS}'
WHERE \`name\` IN ('admin_password','password','system_password');

UPDATE \`${table}\`
SET value='${SYS_KEY}'
WHERE \`name\` IN ('system_api_key','api_key','apikey');
EOF

    if [[ $? -eq 0 ]]; then
        info "数据库凭据同步完成"
    else
        warn "数据库凭据同步失败"
        return 1
    fi
}

show_credentials() {
    local workdir="$1"
    local env_file="${workdir}/.env"

    read_credentials_from_config "${workdir}/config.yaml"

    local host_port
    host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")

    echo ""
    echo "=================================================="
    echo -e "\033[32mCodeFreeMax 实例信息\033[0m"
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
    require_cmd awk

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "安装目录 [默认: ${DEFAULT_INSTALL_PATH}]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && "$(ls -A "$install_path" 2>/dev/null)" ]]; then
        die "目录非空: ${install_path}，请先卸载或换目录"
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "$ENV_RECORD_FILE"

    cd "$install_path" || exit 1

    read -r -p "访问端口 [默认: 8877]: " input_port
    local host_port=${input_port:-8877}

    info "下载 docker-compose.yml 和 config.yaml..."

    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || die "docker-compose.yml 下载失败"
    curl -sSL "$CONFIG_URL" -o config.yaml || die "config.yaml 下载失败"

    generate_credentials
    write_config_credentials "config.yaml"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    mkdir -p data backups
    chmod -R 777 data backups

    info "启动容器..."

    $dc_cmd up -d || die "容器启动失败"

    wait_mysql_ready || die "MySQL 初始化失败"

    sleep 10

    wait_app_ready || true

    inject_db_credentials || true

    show_credentials "$install_path"

    info "如果外网打不开，请放行端口: ${host_port}"
}

upgrade_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    cd "$workdir" || exit 1

    read_credentials_from_config "config.yaml"

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "拉取最新镜像..."
    $dc_cmd pull
    $dc_cmd up -d

    wait_mysql_ready || true
    wait_app_ready || true
    inject_db_credentials || true

    show_credentials "$workdir"
}

pause_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    cd "$workdir" || exit 1
    $(docker_compose_cmd) stop

    info "服务已停止"
}

restart_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    cd "$workdir" || exit 1

    read_credentials_from_config "config.yaml"

    $(docker_compose_cmd) restart

    wait_mysql_ready || true
    wait_app_ready || true
    inject_db_credentials || true

    show_credentials "$workdir"
}

do_backup() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    info "导出 MySQL 数据库..."

    docker exec "$MYSQL_CONTAINER" mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        --single-transaction \
        --routines \
        --triggers \
        "$MYSQL_DB" > "${temp_dir}/mysql.sql"

    info "导出 Redis 数据..."

    docker exec "$REDIS_CONTAINER" redis-cli SAVE >/dev/null 2>&1 || true
    docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "${temp_dir}/dump.rdb" >/dev/null 2>&1 || true

    cp "${workdir}/docker-compose.yml" "${temp_dir}/"
    cp "${workdir}/config.yaml" "${temp_dir}/"
    cp "${workdir}/.env" "${temp_dir}/"

    if [[ -d "${workdir}/data" ]]; then
        cp -r "${workdir}/data" "${temp_dir}/data"
    fi

    local backup_file="${backup_dir}/cfm_backup_${timestamp}.tar.gz"

    tar -czf "$backup_file" -C "$temp_dir" .

    rm -rf "$temp_dir"

    cd "$backup_dir" || exit 1
    ls -t cfm_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份完成: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir=$(get_workdir)

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"

    local latest_backup
    latest_backup=$(ls -t "${search_dir}"/cfm_backup_*.tar.gz 2>/dev/null | head -n 1 || true)

    read -r -p "备份文件路径 [默认: ${latest_backup}]: " backup_path
    local path=${backup_path:-$latest_backup}

    [[ ! -f "$path" ]] && die "备份文件不存在"

    read -r -p "恢复目录 [默认: ${DEFAULT_INSTALL_PATH}]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在，是否覆盖？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return

        cd "$wd" 2>/dev/null && $(docker_compose_cmd) down -v || true
        cd /
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$path" -C "$wd"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || exit 1

    chmod -R 777 data backups 2>/dev/null || true

    read_credentials_from_config "config.yaml"

    info "启动容器..."

    $(docker_compose_cmd) up -d

    wait_mysql_ready || die "MySQL 启动失败"

    sleep 8

    if [[ -f "${wd}/mysql.sql" ]]; then
        info "恢复 MySQL 数据库..."

        docker exec -i "$MYSQL_CONTAINER" mysql \
            -u"$MYSQL_USER" \
            -p"$MYSQL_PASS" \
            "$MYSQL_DB" < "${wd}/mysql.sql"
    else
        warn "备份包内没有 mysql.sql，数据库可能无法恢复"
    fi

    if [[ -f "${wd}/dump.rdb" ]]; then
        info "恢复 Redis 数据..."

        docker cp "${wd}/dump.rdb" "${REDIS_CONTAINER}:/data/dump.rdb" >/dev/null 2>&1 || true
        docker restart "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    fi

    $(docker_compose_cmd) restart codefreemax || true

    sleep 10

    inject_db_credentials || true

    show_credentials "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    local cron_script="${workdir}/cron_backup.sh"
    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    echo "1) 每隔 X 分钟备份"
    echo "2) 每天固定时间备份"
    echo "3) 删除定时备份"

    read -r -p "请选择: " cron_type

    local cron_spec=""

    case "$cron_type" in
        1)
            read -r -p "分钟间隔: " min_interval
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "时间 HH:MM: " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -
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
bash "$script_path" run-backup >> "$BACKUP_LOG" 2>&1
EOF

    chmod +x "$cron_script"

    (
        crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d"
        echo "$CRON_TAG_BEGIN"
        echo "${cron_spec} bash ${cron_script}"
        echo "$CRON_TAG_END"
    ) | crontab -

    info "定时备份已设置"
}

uninstall_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && workdir="$DEFAULT_INSTALL_PATH"

    echo -e "\033[31m警告：这会删除容器、卷和业务数据！\033[0m"

    read -r -p "确认卸载？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down -v || true
        cd /
        rm -rf "$workdir"
    fi

    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab -

    info "已卸载"
}

show_status() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && die "未检测到部署环境"

    cd "$workdir" || exit 1

    docker compose ps 2>/dev/null || docker-compose ps
    echo ""
    ss -tlnp 2>/dev/null | grep -E '8877|63376|codefreemax' || true
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
    echo "9) 查看状态"
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
        9) show_status ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
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
