#!/usr/bin/env bash

#================================================================
# CloudDrive2 多实例一键部署与管理脚本
#================================================================

readonly BASE_DIR="/opt/clouddrive2_manager"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
readonly IMAGE_NAME="cloudnas/clouddrive2-unstable"
readonly MIN_PORT=19798
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

info()    { echo -e "${GREEN}[信息]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*"; }
header()  { echo -e "${CYAN}[*]${NC} $*"; }

#================================================================
# 1. 环境初始化与依赖检测
#================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行。"
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker 已安装。"
    else
        warn "未检测到 Docker，正在通过官方脚本安装..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        info "Docker 安装完成并已启动。"
    fi
}

install_docker_compose() {
    if command -v docker-compose &>/dev/null; then
        info "docker-compose 已安装。"
    elif docker compose version &>/dev/null 2>&1; then
        info "docker compose 插件已可用。"
    else
        warn "未检测到 docker-compose，正在安装..."
        curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        info "docker-compose 安装完成。"
    fi
}

detect_compose_cmd() {
    if command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    elif docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        error "未找到 docker-compose 命令。"
        exit 1
    fi
}

check_fuse() {
    if [[ ! -c /dev/fuse ]]; then
        warn "未找到 /dev/fuse，正在尝试加载 fuse 内核模块..."
        modprobe fuse 2>/dev/null || true
        if [[ ! -c /dev/fuse ]]; then
            error "/dev/fuse 不可用，CD2 挂载功能可能无法正常工作。"
        else
            info "fuse 内核模块加载成功。"
        fi
    else
        info "/dev/fuse 可用。"
    fi
}

init_directories() {
    mkdir -p "${BASE_DIR}"
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        cat > "${COMPOSE_FILE}" <<'YAML'
services:
YAML
        info "已创建 docker-compose.yml。"
    fi
}

env_init() {
    check_root
    install_docker
    install_docker_compose
    detect_compose_cmd
    check_fuse
    init_directories
}

#================================================================
# 辅助函数
#================================================================

is_port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${1} " || netstat -tlnp 2>/dev/null | grep -q ":${1} "
}

find_available_port() {
    local port=${MIN_PORT}
    while is_port_in_use "${port}"; do
        ((port++))
    done
    echo "${port}"
}

validate_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        return 1
    fi
    return 0
}

service_exists_in_compose() {
    grep -qE "^  \"?${1}\"?:" "${COMPOSE_FILE}" 2>/dev/null
}

list_services() {
    grep -E '^  "?[a-zA-Z_][a-zA-Z0-9_]*"?:' "${COMPOSE_FILE}" 2>/dev/null | sed 's/^  "//;s/^  //;s/":.*//;s/:.*//' || true
}

count_services() {
    list_services | wc -l
}

is_service_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

umount_instance() {
    local target_dir="${BASE_DIR}/${1}"
    info "正在卸载 ${1} 的 FUSE 挂载点..."
    mount | grep "${target_dir}/" | awk '{print $3}' | sort -r | while IFS= read -r mp; do
        [[ -z "${mp}" ]] && continue
        umount -l "${mp}" 2>/dev/null || fusermount -uz "${mp}" 2>/dev/null || true
    done
    mount | grep "${target_dir}/" | awk '{print $3}' | sort -r | while IFS= read -r mp; do
        [[ -z "${mp}" ]] && continue
        fusermount -uz "${mp}" 2>/dev/null || true
    done
}

#================================================================
# 2. 交互式主菜单
#================================================================

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════╗
  ║        CloudDrive2 多实例管理脚本 v1.0              ║
  ╚═══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

show_menu() {
    show_banner
    echo -e "  ${GREEN}1)${NC} 添加新的 CD2 实例"
    echo -e "  ${GREEN}2)${NC} 删除已有的 CD2 实例"
    echo -e "  ${GREEN}3)${NC} 查看当前所有实例运行状态"
    echo -e "  ${GREEN}4)${NC} 一键更新所有实例"
    echo -e "  ${GREEN}5)${NC} 重启指定或全部实例"
    echo -e "  ${GREEN}6)${NC} 生成反向代理配置 (Caddy/Nginx)"
    echo -e "  ${GREEN}7)${NC} 卸载全部实例并清理数据"
    echo -e "  ${RED}0)${NC} 退出脚本"
    echo ""
}

#================================================================
# 3. 核心功能实现
#================================================================

#--- 功能1：添加新实例 ---

add_instance() {
    header "===== 添加新的 CD2 实例 ====="

    local instance_name
    while true; do
        read -rp "请输入实例名称（仅限英文、数字、下划线）: " instance_name
        if [[ -z "${instance_name}" ]]; then
            error "实例名称不能为空。"
            continue
        fi
        if ! validate_name "${instance_name}"; then
            error "名称无效，必须以字母或下划线开头，只能包含英文、数字和下划线。"
            continue
        fi
        if service_exists_in_compose "${instance_name}"; then
            error "实例 '${instance_name}' 已存在于 docker-compose.yml 中。"
            continue
        fi
        break
    done

    local suggested_port
    suggested_port=$(find_available_port)
    local host_port
    while true; do
        read -rp "请输入宿主机映射端口 [默认: ${suggested_port}]: " host_port
        host_port="${host_port:-${suggested_port}}"
        if ! [[ "${host_port}" =~ ^[0-9]+$ ]] || ((host_port < 1 || host_port > 65535)); then
            error "端口号无效，范围应为 1-65535。"
            continue
        fi
        if is_port_in_use "${host_port}"; then
            error "端口 ${host_port} 已被占用。"
            continue
        fi
        break
    done

    local instance_dir="${BASE_DIR}/${instance_name}"
    mkdir -p "${instance_dir}/Config" "${instance_dir}/CloudNAS"
    info "已创建目录: ${instance_dir}/Config, ${instance_dir}/CloudNAS"

    info "正在追加服务到 docker-compose.yml..."
    cat >> "${COMPOSE_FILE}" << YAML
  "${instance_name}":
    image: ${IMAGE_NAME}
    container_name: ${instance_name}
    privileged: true
    pid: "host"
    devices:
      - /dev/fuse:/dev/fuse
    volumes:
      - ./${instance_name}/Config:/Config
      - ./${instance_name}/CloudNAS:/CloudNAS:shared
    ports:
      - "${host_port}:19798"
    restart: unless-stopped
YAML

    info "正在启动实例 '${instance_name}'..."
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d "${instance_name}"

    echo ""
    info "实例 '${instance_name}' 已成功运行。"
    info "访问地址: ${CYAN}http://<你的IP>:${host_port}${NC}"
}

#--- 功能2：删除实例 ---

delete_instance() {
    header "===== 删除已有的 CD2 实例 ====="

    local services
    services=$(list_services)
    if [[ -z "${services}" ]]; then
        warn "当前没有找到任何实例。"
        return
    fi

    echo "可用实例列表:"
    local i=1
    local names=()
    for svc in ${services}; do
        echo -e "  ${CYAN}${i})${NC} ${svc}"
        names+=("${svc}")
        ((i++))
    done

    local choice
    read -rp "请选择要删除的实例编号: " choice
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#names[@]})); then
        error "选择无效。"
        return
    fi

    local target="${names[$((choice - 1))]}"
    local confirm
    read -rp "确认删除实例 '${target}' 吗？(y/N): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        warn "已取消删除。"
        return
    fi

    local delete_data
    read -rp "是否同时删除本地持久化数据（Config 和 CloudNAS 目录）？(y/N): " delete_data

    info "正在停止实例 '${target}'..."
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" stop "${target}" 2>/dev/null || true
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" rm -f "${target}" 2>/dev/null || true

    if [[ "${delete_data,,}" == "y" ]]; then
        umount_instance "${target}"
        info "正在删除数据目录: ${BASE_DIR}/${target}..."
        rm -rf "${BASE_DIR}/${target}" 2>/dev/null || true
        if [[ -d "${BASE_DIR}/${target}" ]]; then
            warn "部分文件可能需要重启后手动删除: ${BASE_DIR}/${target}"
        fi
    fi

    info "正在从 docker-compose.yml 中移除 '${target}'..."
    remove_service_from_compose "${target}"

    info "实例 '${target}' 已成功删除。"
}

remove_service_from_compose() {
    local svc="$1"
    local tmp_file="${COMPOSE_FILE}.tmp"
    local in_block=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*\"?${svc}\"?:[[:space:]]*$ ]]; then
            in_block=1
            continue
        fi
        if [[ ${in_block} -eq 1 ]]; then
            if [[ "${line}" =~ ^[[:space:]]{2}[a-zA-Z0-9_]+:[[:space:]] ]]; then
                in_block=0
                echo "${line}" >> "${tmp_file}"
            fi
            continue
        fi
        echo "${line}" >> "${tmp_file}"
    done < "${COMPOSE_FILE}"

    mv "${tmp_file}" "${COMPOSE_FILE}"
}

#--- 功能3：查看状态 ---

view_status() {
    header "===== CD2 实例运行状态 ====="

    local services
    services=$(list_services)
    if [[ -z "${services}" ]]; then
        warn "当前没有配置任何实例。"
        return
    fi

    printf "${CYAN}%-20s %-15s %-12s %-15s %-12s${NC}\n" \
        "实例名称" "容器ID" "运行状态" "宿主机端口" "内存占用"
    printf "%-20s %-15s %-12s %-15s %-12s\n" \
        "--------" "------------" "------" "---------" "--------"

    for svc in ${services}; do
        local container_id status port mem
        container_id=$(docker ps -a --filter "name=^${svc}$" --format '{{.ID}}' 2>/dev/null || echo "N/A")
        status=$(docker ps -a --filter "name=^${svc}$" --format '{{.Status}}' 2>/dev/null || echo "N/A")

        if [[ "${status}" == Up* ]]; then
            mem=$(docker stats --no-stream --format '{{.MemUsage}}' "${svc}" 2>/dev/null || echo "N/A")
        else
            mem="N/A"
        fi

        local compose_line
        compose_line=$(grep -AE 20 "^  \"?${svc}\"?:" "${COMPOSE_FILE}" | grep -oP '"\K[0-9]+(?=:19798)' | head -1)
        port="${compose_line:-N/A}"

        printf "%-20s %-15s %-12s %-15s %-12s\n" \
            "${svc}" "${container_id}" "${status}" "${port}" "${mem}"
    done
}

#--- 功能4：一键更新 ---

update_all() {
    header "===== 一键更新所有 CD2 实例 ====="

    info "正在拉取最新镜像..."
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" pull

    info "正在使用新镜像重启所有服务..."
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d

    info "正在清理旧镜像..."
    docker image prune -f

    info "所有实例更新完成。"
}

#--- 功能5：重启实例 ---

restart_instances() {
    header "===== 重启 CD2 实例 ====="

    local services
    services=$(list_services)
    if [[ -z "${services}" ]]; then
        warn "当前没有配置任何实例。"
        return
    fi

    echo "可用实例列表:"
    echo -e "  ${CYAN}0)${NC} 重启所有实例"
    local i=1
    local names=()
    for svc in ${services}; do
        echo -e "  ${CYAN}${i})${NC} ${svc}"
        names+=("${svc}")
        ((i++))
    done

    local choice
    read -rp "请选择要重启的实例编号: " choice

    if [[ "${choice}" == "0" ]]; then
        info "正在重启所有实例..."
        ${COMPOSE_CMD} -f "${COMPOSE_FILE}" restart
        info "所有实例已重启。"
    elif [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#names[@]})); then
        local target="${names[$((choice - 1))]}"
        info "正在重启实例 '${target}'..."
        ${COMPOSE_CMD} -f "${COMPOSE_FILE}" restart "${target}"
        info "实例 '${target}' 已重启。"
    else
        error "选择无效。"
    fi
}

#--- 功能6：生成反向代理配置 ---

generate_proxy() {
    header "===== 生成反向代理配置 ====="

    local services
    services=$(list_services)
    if [[ -z "${services}" ]]; then
        warn "当前没有配置任何实例。"
        return
    fi

    local domain
    read -rp "请输入主域名（例如 example.com）: " domain
    if [[ -z "${domain}" ]]; then
        error "域名不能为空。"
        return
    fi

    echo ""
    echo -e "  ${CYAN}1)${NC} Caddy"
    echo -e "  ${CYAN}2)${NC} Nginx"
    local proxy_choice
    read -rp "请选择反向代理类型 [1]: " proxy_choice
    proxy_choice="${proxy_choice:-1}"

    if [[ "${proxy_choice}" == "1" ]]; then
        generate_caddy_config "${domain}" "${services}"
    elif [[ "${proxy_choice}" == "2" ]]; then
        generate_nginx_config "${domain}" "${services}"
    else
        error "选择无效。"
        return
    fi
}

generate_caddy_config() {
    local domain="$1"
    local services="$2"
    local caddyfile="${BASE_DIR}/Caddyfile"

    echo -n "" > "${caddyfile}"
    for svc in ${services}; do
        if is_service_running "${svc}"; then
            local port
            port=$(grep -AE 20 "^  \"?${svc}\"?:" "${COMPOSE_FILE}" | grep -oP '"\K[0-9]+(?=:19798)' | head -1)
            if [[ -n "${port}" ]]; then
                cat >> "${caddyfile}" << CADDY
${svc}.${domain} {
    reverse_proxy localhost:${port}
}

CADDY
            fi
        fi
    done

    info "Caddyfile 已生成: ${caddyfile}"
    echo ""
    cat "${caddyfile}"
}

generate_nginx_config() {
    local domain="$1"
    local services="$2"
    local nginx_conf="${BASE_DIR}/cd2_proxy.conf"

    echo -n "" > "${nginx_conf}"
    for svc in ${services}; do
        if is_service_running "${svc}"; then
            local port
            port=$(grep -AE 20 "^  \"?${svc}\"?:" "${COMPOSE_FILE}" | grep -oP '"\K[0-9]+(?=:19798)' | head -1)
            if [[ -n "${port}" ]]; then
                cat >> "${nginx_conf}" << NGINX
server {
    listen 80;
    server_name ${svc}.${domain};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

NGINX
            fi
        fi
    done

    info "Nginx 配置已生成: ${nginx_conf}"
    info "请复制到 /etc/nginx/conf.d/ 并执行 'nginx -s reload' 使其生效。"
    echo ""
    cat "${nginx_conf}"
}

#--- 功能7：卸载与清理 ---

uninstall_all() {
    header "===== 卸载全部实例并清理数据 ====="

    warn "此操作将停止并删除所有 CD2 容器，且删除所有数据！"
    local confirm
    read -rp "你确定要继续吗？请输入 'YES' 确认: " confirm
    if [[ "${confirm}" != "YES" ]]; then
        info "已取消卸载。"
        return
    fi

    local all_services
    all_services=$(list_services)

    for svc in ${all_services}; do
        info "正在停止实例 '${svc}'..."
        docker stop "${svc}" 2>/dev/null || true
        docker rm -f "${svc}" 2>/dev/null || true
        umount_instance "${svc}"
    done

    info "正在强制卸载所有残余 FUSE 挂载点..."
    mount | grep "${BASE_DIR}/" | awk '{print $3}' | sort -r | while IFS= read -r mp; do
        [[ -z "${mp}" ]] && continue
        umount -l "${mp}" 2>/dev/null || true
        fusermount -uz "${mp}" 2>/dev/null || true
    done

    info "正在删除工作目录: ${BASE_DIR}..."
    rm -rf "${BASE_DIR}" 2>/dev/null || true

    if [[ -d "${BASE_DIR}" ]]; then
        warn "部分文件可能需要重启系统后手动删除: ${BASE_DIR}"
    fi

    info "正在清理 CD2 镜像..."
    docker rmi "${IMAGE_NAME}" 2>/dev/null || true
    docker image prune -f 2>/dev/null || true

    info "所有 CloudDrive2 实例及数据已清理完毕。"
}

#================================================================
# 主循环
#================================================================

main() {
    env_init

    while true; do
        show_menu
        read -rp "请输入你的选择 [0-7]: " choice
        case "${choice}" in
            1) add_instance ;;
            2) delete_instance ;;
            3) view_status ;;
            4) update_all ;;
            5) restart_instances ;;
            6) generate_proxy ;;
            7) uninstall_all ;;
            0) info "再见！"; exit 0 ;;
            *) error "选项无效，请输入 0-7。" ;;
        esac

        echo ""
        read -n 1 -s -r -p "按任意键继续..."
        echo ""
    done
}

main "$@"
