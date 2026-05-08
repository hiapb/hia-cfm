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
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1"
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未探测到 Docker Compose 引擎。"
    fi
}

get_workdir() {
    [[ -f "$ENV_RECORD_FILE" ]] && cat "$ENV_RECORD_FILE" || echo ""
}

mysql_exec() {
    docker exec -i -e MYSQL_PWD="$MYSQL_PASS" "$MYSQL_CONTAINER" mysql -u"$MYSQL_USER" "$MYSQL_DB"
}

mysql_exec_query() {
    docker exec -i -e MYSQL_PWD="$MYSQL_PASS" "$MYSQL_CONTAINER" mysql -u"$MYSQL_USER" -N -B "$MYSQL_DB" -e "$1"
}

mysql_dump() {
    docker exec -e MYSQL_PWD="$MYSQL_PASS" "$MYSQL_CONTAINER" mysqldump \
        -u"$MYSQL_USER" \
        --single-transaction \
        --routines \
        --triggers \
        "$MYSQL_DB"
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
        if docker exec -e MYSQL_PWD="$MYSQL_PASS" "$MYSQL_CONTAINER" mysqladmin ping -u"$MYSQL_USER" >/dev/null 2>&1; then
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
    docker logs --tail=80 codefreemax 2>/dev/null || true
    return 1
}

inject_db_credentials() {
    info "等待业务配置表初始化..."

    local table=""
    local key_col=""
    local value_col=""

    for i in {1..90}; do
        table=$(mysql_exec_query "
SELECT c1.TABLE_NAME
FROM information_schema.COLUMNS c1
JOIN information_schema.COLUMNS c2
  ON c1.TABLE_SCHEMA=c2.TABLE_SCHEMA
 AND c1.TABLE_NAME=c2.TABLE_NAME
WHERE c1.TABLE_SCHEMA='${MYSQL_DB}'
  AND c1.COLUMN_NAME IN ('key','name','config_key')
  AND c2.COLUMN_NAME IN ('value','config_value')
LIMIT 1;
" 2>/dev/null | head -n 1 || true)

        [[ -n "$table" ]] && break
        sleep 2
    done

    if [[ -z "$table" ]]; then
        warn "未找到真正的系统配置表，跳过数据库同步。"
        warn "密码/API Key 已写入 config.yaml。"
        return 1
    fi

    key_col=$(mysql_exec_query "
SELECT COLUMN_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='${MYSQL_DB}'
  AND TABLE_NAME='${table}'
  AND COLUMN_NAME IN ('key','name','config_key')
LIMIT 1;
" 2>/dev/null | head -n 1)

    value_col=$(mysql_exec_query "
SELECT COLUMN_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='${MYSQL_DB}'
  AND TABLE_NAME='${table}'
  AND COLUMN_NAME IN ('value','config_value')
LIMIT 1;
" 2>/dev/null | head -n 1)

    if [[ -z "$key_col" || -z "$value_col" ]]; then
        warn "配置表字段识别失败，跳过数据库同步。"
        return 1
    fi

    info "检测到配置表: ${table}"
    info "同步密码/API Key 到数据库..."

    mysql_exec <<EOF
UPDATE \`${table}\`
SET \`${value_col}\`='${SYS_PASS}'
WHERE \`${key_col}\` IN (
    'admin_password',
    'password',
    'system_password',
    'admin.pass',
    'admin_password_hash'
);

UPDATE \`${table}\`
SET \`${value_col}\`='${SYS_KEY}'
WHERE \`${key_col}\` IN (
    'system_api_key',
    'api_key',
    'apikey',
    'system.key'
);
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
    echo -e "\033[32m✅ CodeFreeMax 实例就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "控制面板: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "--------------------------------------------------"
    echo -e "面板密码: \033[31m${SYS_PASS}\033[0m"
    echo -e "系统 API Key: \033[33m${SYS_KEY}\033[0m"
    echo "=================================================="
    echo ""
}

show_access_only() {
    local workdir="$1"
    local env_file="${workdir}/.env"

    local host_port
    host_port=$(grep -oP '^PORT=\K.*' "$env_file" 2>/dev/null || echo "8877")

    echo ""
    echo "=================================================="
    echo -e "\033[32m✅ CodeFreeMax 服务已就绪\033[0m"
    echo "--------------------------------------------------"
    echo -e "控制面板: \033[36mhttp://$(get_local_ip):${host_port}\033[0m"
    echo "=================================================="
    echo ""
}

deploy_codefreemax() {
    info "== 启动 CodeFreeMax 自动化部署编排 =="

    require_cmd docker
    require_cmd curl
    require_cmd openssl
    require_cmd tar
    require_cmd awk

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

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

    valid_port "$host_port" || die "端口不合法，必须是 1-65535"

    info "正在拉取核心拓扑文件..."

    curl -sSL "$COMPOSE_URL" -o docker-compose.yml || die "拓扑同步失败"
    curl -sSL "$CONFIG_URL" -o config.yaml || die "配置树同步失败"

    generate_credentials
    write_config_credentials "config.yaml"

    cat > .env <<EOF
PORT=${host_port}
TZ=Asia/Shanghai
EOF

    mkdir -p data backups
    chmod -R 777 data backups

    info "正在拉起微服务矩阵..."

    $dc_cmd up -d || die "容器启动失败"

    wait_mysql_ready || die "MySQL 初始化失败"

    sleep 10

    wait_app_ready || true

    inject_db_credentials || true

    show_credentials "$install_path"
}

upgrade_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到运行中的网关，请先执行 [1] 一键部署。"
        return
    }

    cd "$workdir" || return

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "正在拉取最新镜像并重建容器..."

    $dc_cmd pull || die "镜像拉取失败"
    $dc_cmd up -d || die "服务启动失败"

    wait_mysql_ready || true
    wait_app_ready || true

    show_access_only "$workdir"
}

pause_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    cd "$workdir" && $(docker_compose_cmd) stop
    info "服务已停止。"
}

restart_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    cd "$workdir" || return

    $(docker_compose_cmd) restart

    wait_mysql_ready || true
    wait_app_ready || true

    show_access_only "$workdir"
}

do_backup() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    local temp_dir="${backup_dir}/tmp_${timestamp}"
    mkdir -p "$temp_dir"

    info "导出 MySQL 数据库..."
    mysql_dump > "${temp_dir}/mysql.sql" || die "MySQL 导出失败"

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

    cd "$backup_dir" || return

    ls -t cfm_backup_*.tar.gz 2>/dev/null | awk 'NR>5' | xargs -r rm -f

    info "备份执行完毕。当前可用备份如下: ${backup_file}"
}

restore_backup() {
    local workdir
    workdir=$(get_workdir)

    local search_dir="${workdir:-$DEFAULT_INSTALL_PATH}/backups"

    local default_backup
    default_backup=$(ls -t "${search_dir}"/cfm_backup_*.tar.gz 2>/dev/null | head -n 1 || true)

    read -r -p "请输入备份文件路径 [直接回车使用默认: ${default_backup}]: " backup_path
    local path=${backup_path:-$default_backup}

    [[ ! -f "$path" ]] && {
        err "未找到有效的快照文件。"
        return
    }

    local safe_backup="/tmp/$(basename "$path")"
    cp "$path" "$safe_backup" || die "备份文件复制到临时目录失败"

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " target_dir
    local wd=${target_dir:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$wd" ]]; then
        read -r -p "目标目录已存在实例，是否强制覆盖？(y/N): " confirm

        [[ ! "$confirm" =~ ^[Yy]$ ]] && {
            rm -f "$safe_backup"
            return
        }

        cd "$wd" 2>/dev/null && $(docker_compose_cmd) down -v 2>/dev/null || true
        docker rm -f codefreemax cfm-client-mysql cfm-client-redis 2>/dev/null || true
        docker volume rm codefreemax_mysql-data codefreemax_redis-data 2>/dev/null || true
        docker network rm codefreemax_default 2>/dev/null || true

        cd /
        rm -rf "$wd"
    fi

    mkdir -p "$wd"
    tar -xzf "$safe_backup" -C "$wd" || die "解压备份失败"

    mkdir -p "${wd}/backups"
    cp "$safe_backup" "${wd}/backups/$(basename "$safe_backup")" 2>/dev/null || true
    rm -f "$safe_backup"

    echo "$wd" > "$ENV_RECORD_FILE"

    cd "$wd" || return

    chmod -R 777 data backups 2>/dev/null || true

    info "启动恢复后的容器..."

    $(docker_compose_cmd) up -d || die "容器启动失败"

    wait_mysql_ready || die "MySQL 启动失败"

    sleep 8

    if [[ -f "${wd}/mysql.sql" ]]; then
        info "恢复 MySQL 数据库..."
        mysql_exec < "${wd}/mysql.sql" || die "MySQL 恢复失败"
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

    show_access_only "$wd"
}

setup_auto_backup() {
    require_cmd crontab

    info "== 定时备份策略管控 =="

    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    local cron_script="${workdir}/cron_backup.sh"
    local script_path
    script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    echo " 1) 按固定分钟步进备份（推荐：1/2/3/4/5/6/10/12/15/20/30）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"

    read -r -p "请选择策略 [1/2/3]: " cron_type

    local cron_spec=""

    case "$cron_type" in
        1)
            read -r -p "请输入间隔分钟数: " min_interval
            [[ "$min_interval" =~ ^[0-9]+$ ]] || {
                err "分钟数无效"
                return
            }
            cron_spec="*/${min_interval} * * * *"
        ;;
        2)
            read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
            local hour="${cron_time%:*}"
            local minute="${cron_time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]] || {
                err "时间格式无效"
                return
            }
            cron_spec="${minute} ${hour} * * *"
        ;;
        3)
            crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true
            rm -f "$cron_script"
            info "定时任务已注销。"
            return
        ;;
        *)
            err "无效选择"
            return
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

    info "新的定时任务已注入。"
}

clean_all_codefreemax() {
    info "强制清理 CodeFreeMax 容器..."
    docker rm -f codefreemax cfm-client-mysql cfm-client-redis 2>/dev/null || true

    info "强制清理 CodeFreeMax 数据卷..."
    docker volume rm codefreemax_mysql-data codefreemax_redis-data 2>/dev/null || true

    info "强制清理 CodeFreeMax 网络..."
    docker network rm codefreemax_default 2>/dev/null || true
}

uninstall_service() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && workdir=$DEFAULT_INSTALL_PATH

    echo -e "\033[31m⚠️ 警告：这将彻底摧毁所有容器及业务数据！\033[0m"

    read -r -p "确认完全卸载？(y/N): " confirm

    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if [[ -d "$workdir" ]]; then
        cd "$workdir" 2>/dev/null && $(docker_compose_cmd) down -v 2>/dev/null || true
    fi

    clean_all_codefreemax

    cd /
    rm -rf "$workdir"
    rm -f "$ENV_RECORD_FILE"

    crontab -l 2>/dev/null | sed "/${CRON_TAG_BEGIN}/,/${CRON_TAG_END}/d" | crontab - 2>/dev/null || true

    info "容器及业务数据已被安全抹除。"
}

install_ftp(){
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

show_status() {
    local workdir
    workdir=$(get_workdir)

    [[ -z "$workdir" ]] && {
        err "未检测到部署环境。"
        return
    }

    cd "$workdir" || return

    $(docker_compose_cmd) ps
    echo ""
    docker logs --tail=80 codefreemax 2>/dev/null || true
}

main_menu() {
    clear
    echo "==================================================="
    echo "                 CodeFreeMax 一键管理              "
    echo "==================================================="
    local wd
    wd=$(get_workdir)
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
    if [[ $EUID -ne 0 ]]; then
        die "权限收敛：必须使用 Root 权限执行脚本。"
    fi

    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
