#!/bin/bash

# 安装组件列表（包含所有组件）
install_components=("nginx" "nodejs" "pm2" "sqlite" "redis" "acme")

# 卸载组件列表（包含所有组件）
uninstall_components=("acme" "redis" "sqlite" "pm2" "nodejs" "nginx")

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以 root 用户运行，请使用 sudo 或切换到 root 用户。"
    exit 1
fi

# 更新系统包列表
update_sources() {
    echo "正在更新系统包列表..."
    if ! apt update -y; then
        echo "错误：无法更新包列表，请检查网络或权限。"
        exit 1
    fi
    echo "系统包列表已更新。"
}

# 获取公网 IP 地址
get_public_ip() {
    local ipv4 ipv6
    ipv4=$(curl -s myip.ipip.net | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' || echo "未检测到")
    ipv6=$(curl -s -6 ip.sb || echo "未检测到")
    echo "公网 IPv4: $ipv4"
    echo "公网 IPv6: $ipv6"
}

# 检查并创建 Nginx 配置目录
check_nginx_dirs() {
    local dirs=("/etc/nginx/sites-available" "/etc/nginx/sites-enabled")
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" || {
                echo "错误：无法创建目录 $dir"
                exit 1
            }
        fi
    done
}

# 生成 Diffie-Hellman 参数文件
generate_dhparam() {
    local dhparam_file="/etc/nginx/ssl/dhparam.pem"
    if [ ! -f "$dhparam_file" ]; then
        echo "正在生成 Diffie-Hellman 参数文件（可能需要几分钟）..."
        mkdir -p /etc/nginx/ssl/ || {
            echo "错误：无法创建 SSL 目录"
            exit 1
        }
        if ! openssl dhparam -out "$dhparam_file" 2048; then
            echo "错误：生成 DH 参数文件失败"
            exit 1
        fi
        chmod 600 "$dhparam_file"
        echo "dhparam.pem 已生成。"
    else
        echo "警告：dhparam.pem 已存在，跳过生成。"
    fi
}

# 查看所有组件服务状态和配置信息
show_status() {
    echo "===== 服务状态和配置信息 ====="

    # Nginx 状态
    echo "Nginx:"
    if command -v nginx &>/dev/null; then
        local nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "未运行")
        echo "  - 状态: $nginx_status"
        if [ "$nginx_status" == "active" ]; then
            echo "  - 监听端口: $(ss -tlnp | grep nginx | awk '{print $4}' | tr '\n' ' ' || echo '未知')"
        fi
        echo "  - 配置文件: /etc/nginx/nginx.conf"
        if [ -d "/etc/nginx/sites-enabled" ]; then
            echo "  - 网站配置: /etc/nginx/sites-enabled/"
            ls /etc/nginx/sites-enabled/ 2>/dev/null || echo "    - 无网站配置"
        else
            echo "  - 网站配置: 未配置"
        fi
    else
        echo "  - 未安装"
    fi

    # Node.js 状态
    echo "Node.js:"
    if command -v node &>/dev/null; then
        echo "  - 版本: $(node -v)"
        echo "  - 安装路径: $(which node)"
    else
        echo "  - 未安装"
    fi

    # pm2 状态
    echo "pm2:"
    if command -v pm2 &>/dev/null; then
        local pm2_status=$(pm2 list 2>/dev/null)
        if [ -z "$pm2_status" ]; then
            echo "  - 状态: 未运行任何应用"
        else
            echo "  - 状态: 运行中"
            echo "  - 应用列表:"
            pm2 list
        fi
    else
        echo "  - 未安装"
    fi

    # Redis 状态
    echo "Redis:"
    if command -v redis-server &>/dev/null; then
        local redis_status=$(systemctl is-active redis-server 2>/dev/null || echo "未运行")
        echo "  - 状态: $redis_status"
        if [ "$redis_status" == "active" ]; then
            echo "  - 监听端口: $(ss -tlnp | grep redis | awk '{print $4}' | tr '\n' ' ' || echo '未知')"
        fi
        echo "  - 配置文件: /etc/redis/redis.conf"
    else
        echo "  - 未安装"
    fi

    # acme.sh 状态
    echo "acme.sh:"
    if [ -d "/root/.acme.sh" ]; then
        echo "  - 安装状态: 已安装"
        echo "  - 证书路径: /root/.acme.sh/"
        ls /root/.acme.sh/*/fullchain.cer 2>/dev/null || echo "    - 无证书"
    else
        echo "  - 未安装"
    fi

    echo "============================="
}

# 安装组件函数
install_nginx() {
    # 检查是否已安装
    if command -v nginx &>/dev/null; then
        echo "Nginx 已安装，跳过安装。"
        return
    fi   
    echo "正在安装 Nginx..."
    if ! apt install -y nginx; then
        echo "错误：Nginx 安装失败"
        exit 1
    fi
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    local script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "$script_dir/nginx.conf" ]; then
        cp "$script_dir/nginx.conf" /etc/nginx/nginx.conf
        rm -f /etc/nginx/conf.d/default.conf 2>/dev/null
    else
        echo "警告：未找到自定义 nginx.conf，保留默认配置"
    fi
    check_nginx_dirs
    generate_dhparam
    if nginx -t; then
        systemctl restart nginx
        echo "Nginx 安装并配置完成。"
    else
        echo "错误：Nginx 配置验证失败，已恢复备份"
        cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
        systemctl restart nginx
        exit 1
    fi
}

install_nodejs() {
    # 检查是否已安装
    if command -v node &>/dev/null; then
        echo "Node.js 已安装，跳过安装。"
        return
    fi
    echo "正在安装 Node.js..."
    if ! curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || ! apt install -y nodejs; then
        echo "错误：Node.js 安装失败"
        exit 1
    fi
    echo "Node.js 已安装。"
}

install_pm2() {
    # 检查是否已安装
    if command -v pm2 &>/dev/null; then
        echo "pm2 已安装，跳过安装。"
        return
    fi
    if ! command -v node &>/dev/null; then
        install_nodejs
    fi
    echo "正在安装 pm2..."
    if ! npm install -g pm2; then
        echo "错误：pm2 安装失败"
        exit 1
    fi
    echo "pm2 已安装。"
}

install_sqlite() {
    # 检查 Node.js 是否安装，未安装则调用安装函数
    if ! command -v node &>/dev/null; then
        install_nodejs
    fi

    # 检查是否已全局安装 sqlite3
    if npm ls -g sqlite3 --depth=0 >/dev/null 2>&1; then
        echo "SQLite 已安装，跳过安装。"
    else
        echo "正在安装 SQLite..."
        if ! npm install -g sqlite3; then
            echo "错误：SQLite 安装失败"
            exit 1
        fi
        echo "SQLite 已安装。"
    fi
}

install_redis() {
    # 检查是否已安装
    if command -v redis-server &>/dev/null; then
        echo "Redis 已安装，跳过安装。"
        return
    fi
    echo "正在安装 Redis..."
    if ! apt install -y redis-server; then
        echo "错误：Redis 安装失败"
        exit 1
    fi
    if [ ! -d "/var/lib/redis" ]; then
        mkdir -p /var/lib/redis || {
            echo "错误：无法创建 Redis 数据目录"
            exit 1
        }
        chown -R redis:redis /var/lib/redis
        chmod -R 755 /var/lib/redis
        echo "Redis 数据目录已创建并配置权限。"
    fi
    systemctl restart redis-server
    echo "Redis 已安装并启动。"
}

install_acme() {
    # 检查是否已安装
    if [ -d "/root/.acme.sh" ]; then
        echo "acme.sh 已安装，跳过安装。"
        return
    fi
    echo "正在安装 acme.sh..."
    if ! curl https://get.acme.sh | sh; then
        echo "错误：acme.sh 安装失败"
        exit 1
    fi
    echo "acme.sh 已安装。"
}

install_all() {
    update_sources
    for comp in "${install_components[@]}"; do
        echo "安装 $comp..."
        "install_$comp"
    done
    echo "所有组件安装完成。"
}

# 卸载组件函数
uninstall_nginx() {
    # 检测 Nginx 是否安装
    if ! command -v nginx &>/dev/null && [ ! -d "/etc/nginx" ]; then
        echo "Nginx 未安装，跳过卸载。"
        return
    fi

    systemctl stop nginx 2>/dev/null
    # 检查网站目录是否存在
    if [ -d "/var/www" ] && [ "$(ls -A /var/www)" ]; then
        echo "检测到网站目录存在于 /var/www 下："
        ls -1 /var/www
        read -p "是否删除所有网站目录？(n/Y): " delete_dirs
        if [[ -z "$delete_dirs" || "$delete_dirs" =~ ^[yY]$ ]]; then
            echo "正在删除网站目录..."
            rm -rf /var/www/*
            echo "网站目录已删除。"
        else
            echo "网站目录将保留。"
        fi
    else
        echo "未检测到网站目录。"
    fi
    # 卸载 Nginx
    apt remove -y --purge nginx
    rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
    echo "Nginx 已卸载。"
}

uninstall_nodejs() {
    # 检测 Node.js 是否安装
    if ! command -v node &>/dev/null; then
        echo "Node.js 未安装，跳过卸载。"
        return
    fi

    apt remove -y --purge nodejs
    rm -rf /usr/local/lib/node_modules
    rm -rf /usr/lib/node_modules
    echo "Node.js 已卸载。"
}

uninstall_sqlite() {
    if command -v npm &>/dev/null; then
        # 检查是否全局安装了 sqlite3（条件取反逻辑修复）
        if ! npm ls -g sqlite3 --depth=0 >/dev/null 2>&1; then
            echo "SQLite 未安装，跳过卸载。"
            return
        fi
        # 执行卸载
        npm uninstall -g sqlite3
        echo "SQLite 已卸载。"
    else
        echo "警告：npm 未安装，无法卸载 SQLite"
    fi
}

uninstall_pm2() {
    if command -v npm &>/dev/null; then
    # 检测 pm2 是否安装
    if ! command -v pm2 &>/dev/null; then
        echo "pm2 未安装，跳过卸载。"
        return
    fi
    npm uninstall -g pm2
    echo "pm2 已卸载。"
    else
        echo "警告：npm 未安装，无法卸载 pm2"
    fi
}

uninstall_redis() {
    if ! command -v redis-server &>/dev/null; then
        echo "Redis 未安装，跳过卸载。"
        return
    fi
    systemctl stop redis-server 2>/dev/null
    apt remove -y --purge redis-server
    rm -rf /var/lib/redis
    echo "Redis 已卸载。"
}

uninstall_acme() {
    if [ ! -d "/root/.acme.sh" ]; then
        echo "acme.sh 未安装，跳过卸载。"
        return
    fi
    rm -rf /root/.acme.sh
    echo "acme.sh 已卸载。"
}

uninstall_all() {
    for comp in "${uninstall_components[@]}"; do
        echo "卸载 $comp..."
        "uninstall_$comp"
    done
    echo "所有组件已卸载。"
}

# SSL 证书管理
manage_ssl() {
    echo "===== SSL 证书管理 ====="
    echo "1. 申请泛域名证书（Cloudflare）"
    echo "2. 申请泛域名证书（阿里云）"
    echo "3. 删除证书"
    echo "4. 部署证书到 Nginx"
    read -p "请选择操作（输入数字）: " ssl_choice
    case $ssl_choice in
    1)
        read -p "请输入 Cloudflare API Token: " cf_token
        read -p "请输入 Cloudflare Zone ID: " cf_zone_id
        read -p "请输入泛域名（例如 *.example.com）: " domain
        if ! echo "$domain" | grep -qE '^\*\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            echo "错误：泛域名格式无效（应为 *.example.com）"
            return
        fi
        export CF_Token="$cf_token" CF_Zone_ID="$cf_zone_id"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength 2048
        echo "证书申请完成，路径：/root/.acme.sh/$domain"
        ;;
    2)
        read -p "请输入阿里云 Access Key ID: " ali_key
        read -p "请输入阿里云 Access Key Secret: " ali_secret
        read -p "请输入泛域名（例如 *.example.com）: " domain
        if ! echo "$domain" | grep -qE '^\*\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            echo "错误：泛域名格式无效（应为 *.example.com）"
            return
        fi
        export Ali_Key="$ali_key" Ali_Secret="$ali_secret"
        ~/.acme.sh/acme.sh --issue --dns dns_ali -d "$domain" --keylength 2048
        echo "证书申请完成，路径：/root/.acme.sh/$domain"
        ;;
    3)
        read -p "请输入要删除的证书域名（例如 example.com）: " domain
        if [ -z "$domain" ] || ! [ -d "/root/.acme.sh/$domain" ]; then
            echo "错误：域名无效或证书不存在"
            return
        fi
        rm -rf "/root/.acme.sh/$domain"
        echo "证书 $domain 已删除。"
        ;;
    4)
        read -p "请输入证书域名（例如 example.com）: " domain
        if [ ! -f "/root/.acme.sh/$domain/fullchain.cer" ] || [ ! -f "/root/.acme.sh/$domain/$domain.key" ]; then
            echo "错误：证书文件不存在，请先申请证书"
            return
        fi
        mkdir -p /etc/nginx/ssl/"$domain"
        cp /root/.acme.sh/"$domain"/fullchain.cer /etc/nginx/ssl/"$domain"/fullchain.pem
        cp /root/.acme.sh/"$domain"/"$domain".key /etc/nginx/ssl/"$domain"/privkey.pem
        chmod 600 /etc/nginx/ssl/"$domain"/*
        echo "证书已部署到 /etc/nginx/ssl/$domain"
        ;;
    *) echo "无效选项。" ;;
    esac
}

# 网站管理
manage_website() {
    echo "===== 当前服务器公网 IP 地址 ====="
    get_public_ip
    echo "------------------------------------"
    echo "1. 配置静态网站"
    echo "2. 配置反向代理"
    echo "3. 启用/禁用 SSL"
    echo "4. 配置 HTTPS 重定向"
    echo "5. 删除网站配置"
    echo "6. 停用/启用网站"
    read -p "请选择操作（输入数字）: " web_choice
    case $web_choice in
    1)
        local script_dir=$(dirname "${BASH_SOURCE[0]}")
        local backup_dir="$script_dir/backups"
        mkdir -p "$backup_dir" 2>/dev/null

        read -p "请输入监听端口（默认 80）: " listen_port
        listen_port=${listen_port:-80}
        if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
            echo "错误：端口号必须为 1-65535 之间的数字"
            return
        fi
        read -p "请输入网站域名（留空允许所有域名）: " domains
        domains=${domains:-_}
        local dir_name
        [ "$domains" == "_" ] && dir_name="default" || dir_name=$(echo "$domains" | awk '{print $1}' | sed 's/[^a-zA-Z0-9]/_/g')
        
        # 检查备份并提示还原
        local backup_file="$backup_dir/${dir_name}_static.tar.gz"
        if [ -f "$backup_file" ]; then
            read -p "发现备份文件 $backup_file，是否还原？(y/n): " restore_choice
            if [ "$restore_choice" == "y" ]; then
                echo "正在还原备份..."
                tar -xzf "$backup_file" -C / 2>/dev/null || {
                    echo "错误：还原备份失败"
                    return
                }
                ln -sf "/etc/nginx/sites-available/$dir_name" "/etc/nginx/sites-enabled/" 2>/dev/null
                systemctl reload nginx
                echo "还原完成。访问地址：http://$(hostname -I | awk '{print $1}'):$listen_port"
                return
            fi
        fi

        local root_dir="/var/www/$dir_name"
        mkdir -p "$root_dir" || {
            echo "错误：无法创建目录 $root_dir"
            return
        }
        chown -R www-data:www-data "$root_dir"
        chmod -R 755 "$root_dir"
        cat <<EOF >"$root_dir/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $domains</title>
</head>
<body>
    <h1>$domains 已成功部署！</h1>
    <p>公网访问：http://$(curl -s myip.ipip.net)</p>
    <p>局域网访问：http://$(hostname -I | awk '{print $1}')</p>
</body>
</html>
EOF
        local config_file="/etc/nginx/sites-available/$dir_name"
        cat <<EOF >"$config_file"
server {
    listen 0.0.0.0:$listen_port;
    server_name $domains;
    root $root_dir;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
        ln -sf "$config_file" /etc/nginx/sites-enabled/
        if nginx -t; then
            systemctl reload nginx
            echo "静态网站配置完成！访问地址：http://$(hostname -I | awk '{print $1}'):$listen_port"
        else
            echo "错误：Nginx 配置验证失败"
            rm -f "$config_file" "/etc/nginx/sites-enabled/$dir_name"
            return
        fi
        ;;

    2)
        local script_dir=$(dirname "${BASH_SOURCE[0]}")
        local backup_dir="$script_dir/backups"
        mkdir -p "$backup_dir" 2>/dev/null

        read -p "请输入监听端口（留空自动生成随机端口）: " listen_port
        if [ -z "$listen_port" ]; then
            while true; do
                listen_port=$((RANDOM % 20000 + 10000))
                ss -tln | grep -q ":$listen_port " || break
            done
            echo "已自动分配监听端口：$listen_port"
        elif ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ] || ss -tln | grep -q ":$listen_port "; then
            echo "错误：端口无效或已被占用"
            return
        fi
        read -p "请输入域名（留空允许所有域名）: " domains
        domains=${domains:-_}
        read -p "请输入后端服务IP（默认 0.0.0.0）: " backend_ip
        backend_ip=${backend_ip:-0.0.0.0}
        read -p "请输入后端服务端口（留空自动生成随机端口）: " backend_port
        if [ -z "$backend_port" ]; then
            while true; do
                backend_port=$((RANDOM % 20000 + 10000))
                ss -tln | grep -q ":$backend_port " || break
            done
            echo "已自动分配后端端口：$backend_port"
        elif ! [[ "$backend_port" =~ ^[0-9]+$ ]] || [ "$backend_port" -lt 1 ] || [ "$backend_port" -gt 65535 ]; then
            echo "错误：后端端口无效"
            return
        fi
        local config_name="proxy_$listen_port"
        
        # 检查备份并提示还原
        local backup_file="$backup_dir/${config_name}_proxy.tar.gz"
        if [ -f "$backup_file" ]; then
            read -p "发现备份文件 $backup_file，是否还原？(y/n): " restore_choice
            if [ "$restore_choice" == "y" ]; then
                echo "正在还原备份..."
                tar -xzf "$backup_file" -C / 2>/dev/null || {
                    echo "错误：还原备份失败"
                    return
                }
                ln -sf "/etc/nginx/sites-available/$config_name" "/etc/nginx/sites-enabled/" 2>/dev/null
                systemctl reload nginx
                echo "还原完成。前端端口：$listen_port，后端地址：$backend_ip:$backend_port"
                return
            fi
        fi

        local config_file="/etc/nginx/sites-available/$config_name"
        cat <<EOF >"$config_file"
server {
    listen 0.0.0.0:$listen_port;
    server_name $domains;
    location / {
        proxy_pass http://$backend_ip:$backend_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
        ln -sf "$config_file" /etc/nginx/sites-enabled/
        if nginx -t; then
            systemctl reload nginx
            echo "反向代理配置完成！前端端口：$listen_port，后端地址：$backend_ip:$backend_port"
        else
            echo "错误：Nginx 配置验证失败"
            rm -f "$config_file" "/etc/nginx/sites-enabled/$config_name"
            return
        fi
        ;;
    3)
        read -p "请输入网站域名对应的配置名称: " config_name
        if [ ! -f "/etc/nginx/sites-available/$config_name" ]; then
            echo "错误：配置 $config_name 不存在"
            return
        fi
        read -p "启用 SSL？（y/n）: " enable_ssl
        local config_file="/etc/nginx/sites-available/$config_name"
        if [ "$enable_ssl" == "y" ]; then
            if [ ! -f "/etc/nginx/ssl/$config_name/fullchain.pem" ]; then
                echo "错误：SSL 证书未部署，请先部署证书"
                return
            fi
            sed -i '/listen 80;/a\    listen 443 ssl;' "$config_file"
            sed -i "/server_name/a\    ssl_certificate /etc/nginx/ssl/$config_name/fullchain.pem;" "$config_file"
            sed -i "/server_name/a\    ssl_certificate_key /etc/nginx/ssl/$config_name/privkey.pem;" "$config_file"
            echo "SSL 已启用。"
        else
            sed -i '/listen 443 ssl;/d' "$config_file"
            sed -i '/ssl_certificate/d' "$config_file"
            sed -i '/ssl_certificate_key/d' "$config_file"
            echo "SSL 已禁用。"
        fi
        nginx -t && systemctl reload nginx || echo "错误：Nginx 配置验证失败"
        ;;
    4)
        read -p "请输入网站域名: " domain
        if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
            echo "错误：域名格式无效"
            return
        fi
        local config_file="/etc/nginx/sites-available/$domain"
        cat <<EOF >"$config_file"
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
EOF
        ln -sf "$config_file" /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx && echo "HTTPS 重定向配置完成。" || echo "错误：Nginx 配置验证失败"
        ;;
    5)
    echo "===== 已配置的网站列表 ====="
    local configs=($(ls /etc/nginx/sites-available/ 2>/dev/null))
    if [ ${#configs[@]} -eq 0 ]; then
        echo "无可用配置"
        return
    fi

    # 显示带编号的配置列表
    echo "请选择要删除的配置："
    for i in "${!configs[@]}"; do
        echo "$((i+1)). ${configs[$i]}"
    done

    read -p "输入配置编号（留空取消）: " config_num
    [ -z "$config_num" ] && return

    # 验证输入是否为有效数字
    if ! [[ "$config_num" =~ ^[0-9]+$ ]] || [ "$config_num" -lt 1 ] || [ "$config_num" -gt ${#configs[@]} ]; then
        echo "错误：无效的编号"
        return
    fi

    # 获取配置名称
    config_name="${configs[$((config_num-1))]}"
    config_path="/etc/nginx/sites-available/$config_name"

    # 默认删除，无需确认
    echo "正在删除配置: $config_name ..."

    # 备份处理（默认不备份，仅当用户输入 y 时备份）
    local script_dir=$(dirname "${BASH_SOURCE[0]}")
    local backup_dir="$script_dir/backups"
    mkdir -p "$backup_dir" || { echo "错误：无法创建备份目录"; return; }

    # 判断是否为静态网站（非 proxy_ 开头）
    if [[ ! "$config_name" =~ ^proxy_ ]]; then
        read -p "是否备份配置和网站目录？[y/N]: " backup_choice
        if [[ "$backup_choice" =~ ^[yY]$ ]]; then
            tar -czf "$backup_dir/${config_name}_static.tar.gz" \
                -C /etc/nginx/sites-available "$config_name" \
                -C /var/www "$config_name" 2>/dev/null || {
                echo "错误：备份失败，请检查权限"
                return
            }
            echo "备份已保存至: $backup_dir/${config_name}_static.tar.gz"
        fi
read -p "是否删除网站目录 /var/www/$config_name？[Y/n]: " delete_dir
# 判断输入为空、Y 或 y（默认回车执行删除）
if [[ -z "$delete_dir" || "$delete_dir" =~ ^[yY]$ ]]; then
    rm -rf "/var/www/$config_name"
    echo "网站目录已删除。"
fi
    else
        read -p "是否备份反向代理配置？[y/N]: " backup_choice
        if [[ "$backup_choice" =~ ^[yY]$ ]]; then
            tar -czf "$backup_dir/${config_name}_proxy.tar.gz" \
                -C /etc/nginx/sites-available "$config_name" 2>/dev/null || {
                echo "错误：备份失败，请检查权限"
                return
            }
            echo "备份已保存至: $backup_dir/${config_name}_proxy.tar.gz"
        fi
    fi

    # 删除配置
    rm -f "$config_path" "/etc/nginx/sites-enabled/$config_name"
    if nginx -t && systemctl reload nginx; then
        echo "网站配置 $config_name 已删除。路径: $config_path"
    else
        echo "错误：Nginx 配置验证失败，已回滚删除操作"
        rm -f "$config_path" "/etc/nginx/sites-enabled/$config_name"  # 确保回滚
        systemctl reload nginx
    fi
    ;;
    6)
        echo "===== 网站配置状态 ====="
        echo "[已启用]:"
        ls /etc/nginx/sites-enabled/ 2>/dev/null || echo "无已启用配置"
        echo "[未启用]:"
        ls /etc/nginx/sites-available/ 2>/dev/null | grep -vxF "$(ls /etc/nginx/sites-enabled/ 2>/dev/null)" || echo "无未启用配置"
        read -p "请输入要操作的配置名称（留空取消）: " config_name
        [ -z "$config_name" ] && return
        if [ ! -f "/etc/nginx/sites-available/$config_name" ]; then
            echo "错误：配置 $config_name 不存在"
            return
        fi
        echo "1. 停用网站  2. 启用网站"
        read -p "选择操作: " action_choice
        case $action_choice in
        1)
            rm -f "/etc/nginx/sites-enabled/$config_name"
            echo "网站 $config_name 已停用。"
            ;;
        2)
            ln -sf "/etc/nginx/sites-available/$config_name" "/etc/nginx/sites-enabled/"
            echo "网站 $config_name 已启用。"
            ;;
        *) echo "无效选项" ;;
        esac
        nginx -t && systemctl reload nginx
        ;;
    *) echo "无效选项" ;;
    esac
}

# 服务管理
manage_service() {
    echo "===== 服务管理 ====="
    echo "1. 一键启动所有服务"
    echo "2. 一键停止所有服务"
    echo "3. 单独管理服务"
    echo "4. 设置开机启动"
    echo "5. 禁用开机启动"
    read -p "请选择操作（输入数字）: " srv_choice
    case $srv_choice in
    1)
        systemctl start nginx 2>/dev/null
        systemctl start redis-server 2>/dev/null
        pm2 start all 2>/dev/null
        echo "所有服务已启动。"
        ;;
    2)
        systemctl stop nginx 2>/dev/null
        systemctl stop redis-server 2>/dev/null
        pm2 stop all 2>/dev/null
        echo "所有服务已停止。"
        ;;
    3)
        echo "选择服务：1. Nginx  2. Redis  3. pm2"
        read -p "输入数字: " srv_sub_choice
        case $srv_sub_choice in
        1) manage_single_service "nginx" ;;
        2) manage_single_service "redis-server" ;;
        3) manage_pm2 ;;
        *) echo "无效选项" ;;
        esac
        ;;
    4)
        echo "选择服务：1. Nginx  2. Redis"
        read -p "输入数字: " boot_choice
        case $boot_choice in
        1) systemctl enable nginx && echo "Nginx 已设置为开机启动。" ;;
        2) systemctl enable redis-server && echo "Redis 已设置为开机启动。" ;;
        *) echo "无效选项" ;;
        esac
        ;;
    5)
        echo "选择服务：1. Nginx  2. Redis"
        read -p "输入数字: " disable_choice
        case $disable_choice in
        1) systemctl disable nginx && echo "Nginx 开机启动已禁用。" ;;
        2) systemctl disable redis-server && echo "Redis 开机启动已禁用。" ;;
        *) echo "无效选项" ;;
        esac
        ;;
    *) echo "无效选项" ;;
    esac
}

manage_single_service() {
    local service=$1
    echo "===== 管理 $service ====="
    echo "1. 启动  2. 停止  3. 重启  4. 查看状态"
    read -p "选择操作: " action_choice
    case $action_choice in
    1) systemctl start "$service" && echo "$service 已启动。" ;;
    2) systemctl stop "$service" && echo "$service 已停止。" ;;
    3) systemctl restart "$service" && echo "$service 已重启。" ;;
    4) systemctl status "$service" ;;
    *) echo "无效选项" ;;
    esac
}

manage_pm2() {
    echo "===== 管理 pm2 ====="
    echo "1. 启动所有应用  2. 停止所有应用  3. 重启所有应用  4. 查看应用状态  5. 管理单个应用"
    read -p "选择操作: " pm2_choice
    case $pm2_choice in
    1) pm2 start all && echo "所有 pm2 应用已启动。" ;;
    2) pm2 stop all && echo "所有 pm2 应用已停止。" ;;
    3) pm2 restart all && echo "所有 pm2 应用已重启。" ;;
    4) pm2 list ;;
    5)
        read -p "请输入 pm2 应用名称: " app_name
        echo "1. 启动  2. 停止  3. 重启  4. 查看状态"
        read -p "选择操作: " app_action
        case $app_action in
        1) pm2 start "$app_name" && echo "$app_name 已启动。" ;;
        2) pm2 stop "$app_name" && echo "$app_name 已停止。" ;;
        3) pm2 restart "$app_name" && echo "$app_name 已重启。" ;;
        4) pm2 show "$app_name" ;;
        *) echo "无效选项" ;;
        esac
        ;;
    *) echo "无效选项" ;;
    esac
}

# 主菜单
while true; do
    echo "===== Debian 12 服务器管理脚本 ====="
    echo "1. 组件管理"
    echo "2. SSL 证书管理"
    echo "3. 网站管理"
    echo "4. 服务管理"
    echo "5. 查看所有组件服务状态"
    echo "6. 退出"
    read -p "请选择操作（输入数字）: " choice
    case $choice in
    1)
        echo "===== 组件管理 ====="
        echo "1. 一键安装所有组件"
        echo "2. 一键卸载所有组件"
        echo "3. 单独安装组件"
        echo "4. 单独卸载组件"
        read -p "选择操作: " comp_choice
        case $comp_choice in
        1) install_all ;;
        2) uninstall_all ;;
        3)
            echo "选择组件：1. Nginx  2. Node.js  3. pm2  4. SQLite  5. Redis  6. acme.sh"
            read -p "输入数字: " inst_choice
            case $inst_choice in
            1) update_sources && install_nginx ;;
            2) update_sources && install_nodejs ;;
            3) update_sources && install_pm2 ;;
            4) update_sources && install_sqlite ;;
            5) update_sources && install_redis ;;
            6) install_acme ;;
            *) echo "无效选项" ;;
            esac
            ;;
        4)
            echo "选择组件：1. Nginx  2. Node.js  3. pm2  4. SQLite  5. Redis  6. acme.sh"
            read -p "输入数字: " uninst_choice
            case $uninst_choice in
            1) uninstall_nginx ;;
            2) uninstall_nodejs ;;
            3) uninstall_pm2 ;;
            4) uninstall_sqlite ;;
            5) uninstall_redis ;;
            6) uninstall_acme ;;
            *) echo "无效选项" ;;
            esac
            ;;
        *) echo "无效选项" ;;
        esac
        ;;
    2) manage_ssl ;;
    3) manage_website ;;
    4) manage_service ;;
    5) show_status ;;
    6)
        echo "退出脚本。"
        exit 0
        ;;
    *) echo "无效选项，请重新选择。" ;;
    esac
done
