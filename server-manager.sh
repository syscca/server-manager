#!/bin/bash

components=("nginx" "pm2" "nodejs" "sqlite" "redis" "acme")

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以 root 用户运行，请使用 sudo 或切换到 root 用户。"
    exit 1
fi

# 更新系统包列表
update_sources() {
    apt update -y
    echo "系统包列表已更新。"
}

# 查看所有组件服务的状态和配置信息
show_status() {
    echo "===== 服务状态和配置信息 ====="

    # 检查 Nginx
    echo "Nginx:"
    if command -v nginx &> /dev/null; then
        nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "未运行")
        echo "  - 状态: $nginx_status"
        if [ "$nginx_status" == "active" ]; then
            echo "  - 监听端口: $(netstat -tlnp | grep nginx | awk '{print $4}' | tr '\n' ' ')"
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

    # 检查 Node.js
    echo "Node.js:"
    if command -v node &> /dev/null; then
        node_version=$(node -v)
        echo "  - 版本: $node_version"
        echo "  - 安装路径: $(which node)"
    else
        echo "  - 未安装"
    fi

    # 检查 pm2
    echo "pm2:"
    if command -v pm2 &> /dev/null; then
        pm2_status=$(pm2 list 2>/dev/null)
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

    # 检查 Redis
    echo "Redis:"
    if command -v redis-server &> /dev/null; then
        redis_status=$(systemctl is-active redis-server 2>/dev/null || echo "未运行")
        echo "  - 状态: $redis_status"
        if [ "$redis_status" == "active" ]; then
            echo "  - 监听端口: $(netstat -tlnp | grep redis | awk '{print $4}' | tr '\n' ' ')"
        fi
        echo "  - 配置文件: /etc/redis/redis.conf"
    else
        echo "  - 未安装"
    fi

    # 检查 acme.sh
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

# 获取公网 IP 地址
get_public_ip() {
    # 使用 myip.ipip.net 获取公网 IPv4 地址
    ipv4=$(curl -s myip.ipip.net | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' || echo "Not found")
    # 使用 ip.sb 获取公网 IPv6 地址
    ipv6=$(curl -s -6 ip.sb || echo "Not found")
    # 输出结果
    echo "公网 IPv4: $ipv4"
    echo "公网 IPv6: $ipv6"
}

# 检查并创建 Nginx 配置目录
check_nginx_dirs() {
    if [ ! -d "/etc/nginx/sites-available" ]; then
        mkdir -p /etc/nginx/sites-available
    fi
    if [ ! -d "/etc/nginx/sites-enabled" ]; then
        mkdir -p /etc/nginx/sites-enabled
    fi
}

generate_dhparam() {
    if [ ! -f "/etc/nginx/ssl/dhparam.pem" ]; then
        echo -e "\033[32m正在生成 Diffie-Hellman 参数文件（可能需要几分钟）...\033[0m"
        mkdir -p /etc/nginx/ssl/
        openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
        chmod 600 /etc/nginx/ssl/dhparam.pem
        echo -e "\033[32mdhparam.pem 已生成。\033[0m"
    else
        echo -e "\033[33m警告：/etc/nginx/ssl/dhparam.pem 已存在，跳过生成。\033[0m"
    fi
}

# 安装组件函数
install_nginx() {
    # 安装 Nginx
    if ! apt install -y nginx; then
        echo "Nginx 安装失败！"
        exit 1
    fi

    # 备份原始配置
    echo -e "\033[32m备份原始配置文件到 /etc/nginx/nginx.conf.bak\033[0m"
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

    # 部署自定义配置
    echo -e "\033[32m正在部署自定义 nginx.conf...\033[0m"
    
    # 获取脚本所在目录的绝对路径
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    
    # 检查本地配置文件是否存在
    if [ ! -f "$script_dir/nginx.conf" ]; then
        echo -e "\033[31m错误：脚本目录中未找到 nginx.conf 文件\033[0m"
        exit 1
    fi

    # 复制配置文件
    cp "$script_dir/nginx.conf" /etc/nginx/nginx.conf

    # 删除默认配置
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    # 检查并创建必要目录
    check_nginx_dirs
    
    # 生成 dhparam.pem
    generate_dhparam

    # 验证配置并重启
    if nginx -t; then
        systemctl restart nginx
        echo -e "\033[32mNginx 自定义配置已生效！\033[0m"
    else
        echo -e "\033[31m错误：Nginx 配置验证失败，已恢复备份\033[0m"
        cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
        systemctl restart nginx
        exit 1
    fi
}

install_nodejs() {
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
    echo "Node.js 已安装。"
}

install_pm2() {
    if ! command -v node &> /dev/null; then
        echo "Node.js 未安装，请先安装 Node.js。"
        install_nodejs
    fi
    npm install -g pm2
    echo "pm2 已安装。"
}

install_sqlite() {
    if ! command -v pm2 &> /dev/null; then
        echo "pm2 未安装，请先安装 pm2。"
        install_pm2
    fi
    npm install -g sqlite3
    echo "sqlite3 已安装。"
}

install_redis() {
    if ! apt install -y redis-server; then
        echo "redis-server 安装失败！"
        exit 1
    fi
    # 修复 Redis 数据目录缺失问题
    echo "正在创建 Redis 数据目录并设置权限..."
    if [ ! -d "/var/lib/redis" ]; then
        mkdir -p /var/lib/redis || { echo "错误：无法创建 /var/lib/redis 目录"; exit 1; }
        chown -R redis:redis /var/lib/redis || { echo "错误：无法设置目录所有者"; exit 1; }
        chmod -R 755 /var/lib/redis || { echo "错误：无法设置目录权限"; exit 1; }
        echo "目录 /var/lib/redis 已创建，权限已配置。"
    else
        echo "目录 /var/lib/redis 已存在，跳过创建。"
    fi
    systemctl restart redis-server
    echo "redis-server 已安装并启动。"
}

install_acme() {
    curl https://get.acme.sh | sh
    echo "acme.sh 已安装。"
}

# 一键安装所有组件
install_all() {
    update_sources
    for comp in "${components[@]}"; do
        install_$comp
    done
    echo "所有组件已安装完成。"
}

# 卸载组件函数
uninstall_nginx() {
    apt remove -y --purge nginx
    rm -rf /etc/nginx /var/log/nginx /var/cache/nginx
    echo "Nginx 已卸载。"
}

uninstall_nodejs() {
    apt remove -y --purge nodejs
    rm -rf /usr/local/lib/node_modules
    echo "Node.js 已卸载。"
}

uninstall_pm2() {
    if ! command -v npm &> /dev/null; then
        echo "警告：npm 未安装，无法卸载 pm2。"
        return
    fi
    npm uninstall -g pm2
    echo "pm2 已卸载。"
}

uninstall_sqlite() {
    npm uninstall -g sqlite3
    echo "SQLite 已卸载。"
}

uninstall_redis() {
    apt remove -y --purge redis-server
    echo "Redis 已卸载。"
}

uninstall_acme() {
    rm -rf /root/.acme.sh
    echo "acme.sh 已卸载。"
}

# 一键卸载所有组件
uninstall_all() {
    for comp in "${components[@]}"; do
        uninstall_$comp
    done
    echo "所有组件已卸载完成。"
}

# SSL 证书管理（占位符，需进一步实现）
manage_ssl() {
    echo "请选择操作："
    echo "1. 申请泛域名证书（Cloudflare）"
    echo "2. 申请泛域名证书（阿里云）"
    echo "3. 删除证书"
    echo "4. 部署证书到 Nginx"
    read ssl_choice
    case $ssl_choice in
        1)
            echo "请输入 Cloudflare API Token："
            read cf_token
            echo "请输入 Cloudflare Zone ID："
            read cf_zone_id
            echo "请输入泛域名（例如 *.example.com）："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi
            export CF_Token="$cf_token"
            export CF_Zone_ID="$cf_zone_id"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --keylength 2048
            echo "证书申请完成，路径：/root/.acme.sh/$domain"
            ;;
        2)
            echo "请输入阿里云 Access Key ID："
            read ali_key
            echo "请输入阿里云 Access Key Secret："
            read ali_secret
            echo "请输入泛域名（例如 *.example.com）："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_secret"
            ~/.acme.sh/acme.sh --issue --dns dns_ali -d "$domain" --keylength 2048
            echo "证书申请完成，路径：/root/.acme.sh/$domain"
            ;;
        3)
            echo "请输入要删除的证书域名（例如 example.com）："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi
            rm -rf /root/.acme.sh/$domain
            echo "证书已删除。"
            ;;
        4)
            echo "请输入证书域名（例如 example.com）："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi           
            mkdir -p /etc/nginx/ssl/$domain
            cp /root/.acme.sh/$domain/fullchain.cer /etc/nginx/ssl/$domain/fullchain.pem
            cp /root/.acme.sh/$domain/$domain.key /etc/nginx/ssl/$domain/privkey.pem
            echo "证书已部署到 /etc/nginx/ssl/$domain"
            ;;
        *) echo "无效选项。" ;;
    esac
}

# 网站管理（占位符，需进一步实现）
manage_website() {
    echo "===== 当前服务器公网 IP 地址 ====="
    get_public_ip
    echo "------------------------------------"
    echo "请选择操作："
    echo "1. 配置静态网站"
    echo "2. 配置反向代理"
    echo "3. 启用/禁用 SSL"
    echo "4. 配置 HTTPS 重定向"
    echo "5. 删除网站配置"
    echo "6. 停用/启用网站"
    read web_choice
    case $web_choice in
        1)
            # 静态网站配置
            echo -n "请输入监听端口（默认 80）："
            read listen_port
            listen_port=${listen_port:-80}

            echo -n "请输入网站域名（留空允许所有域名）："
            read domains
            domains=${domains:-_}

            # 生成目录名
            if [ "$domains" == "_" ]; then
                dir_name="default"
            else
                dir_name=$(echo "$domains" | awk '{print $1}' | sed 's/[^a-zA-Z0-9]/_/g')
            fi

            root_dir="/var/www/$dir_name"
            echo -e "\033[32m网站目录已自动设置为：$root_dir\033[0m"

            # 创建目录并设置权限
            mkdir -p "$root_dir" || {
                echo -e "\033[31m错误：无法创建目录 $root_dir\033[0m"
                return
            }
            chown -R www-data:www-data "$root_dir"
            chmod -R 755 "$root_dir"

            # 生成默认首页
            cat <<EOF > "$root_dir/index.html"
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

            # 生成Nginx配置
            config_file="/etc/nginx/sites-available/$dir_name"
            cat <<EOF > "$config_file"
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

            # 启用配置
            ln -sf "$config_file" /etc/nginx/sites-enabled/
            nginx -t && systemctl reload nginx
            echo -e "\033[32m静态网站配置完成！访问地址：\nhttp://localhost:$listen_port\nhttp://$(hostname -I | awk '{print $1}'):$listen_port\033[0m"
            ;;
2)
    # 反向代理配置
    echo -n "请输入监听端口（留空自动生成随机端口）："
    read listen_port

    # 生成随机未占用端口函数
    find_random_port() {
        while true; do
            port=$((RANDOM%20000+10000))  # 生成 10000-30000 之间的端口
            if ! ss -tuln | grep -q ":$port "; then
                echo $port
                break
            fi
        done
    }

    # 处理端口输入
    if [ -z "$listen_port" ]; then
        listen_port=$(find_random_port)
        echo -e "\033[32m已自动分配监听端口：$listen_port\033[0m"
    else
        # 验证用户输入的端口是否合法
        if ! [[ "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
            echo -e "\033[31m错误：端口号必须为 1-65535 之间的数字\033[0m"
            return
        fi
        # 检查端口是否被占用
        if ss -tuln | grep -q ":$listen_port "; then
            echo -e "\033[31m错误：端口 $listen_port 已被占用\033[0m"
            return
        fi
    fi

    echo -n "请输入域名（留空允许所有域名）："
    read domains
    domains=${domains:-_}

    echo -n "请输入后端服务IP（默认 0.0.0.0）："
    read backend_ip
    backend_ip=${backend_ip:-0.0.0.0}

    echo -n "请输入后端服务端口（留空自动生成随机端口）："
    read backend_port

    # 处理后端端口
    if [ -z "$backend_port" ]; then
        backend_port=$(find_random_port)
        echo -e "\033[32m已自动分配后端端口：$backend_port\033[0m"
    else
        if ! [[ "$backend_port" =~ ^[0-9]+$ ]] || [ "$backend_port" -lt 1 ] || [ "$backend_port" -gt 65535 ]; then
            echo -e "\033[31m错误：端口号必须为 1-65535 之间的数字\033[0m"
            return
        fi
    fi

    # 生成配置文件名（使用监听端口）
    config_name="proxy_$listen_port"
    config_file="/etc/nginx/sites-available/$config_name"

    # 生成Nginx配置
    cat <<EOF > "$config_file"
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

    # 启用配置
    ln -sf "$config_file" /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
    echo -e "\033[32m反向代理配置完成！\n前端监听端口：$listen_port\n后端服务地址：$backend_ip:$backend_port\033[0m"
    ;;
        3)
            echo "请输入网站域名："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi
            echo "启用 SSL？（y/n）："
            read enable_ssl
            config_file="/etc/nginx/sites-available/$domain"
            if [ "$enable_ssl" == "y" ]; then
                sed -i '/listen 80;/a\    listen 443 ssl;' $config_file
                sed -i "/server_name/a\    ssl_certificate /etc/nginx/ssl/$domain/fullchain.pem;" $config_file
                sed -i "/server_name/a\    ssl_certificate_key /etc/nginx/ssl/$domain/privkey.pem;" $config_file
                echo "SSL 已启用。"
            else
                sed -i '/listen 443 ssl;/d' $config_file
                sed -i '/ssl_certificate/d' $config_file
                sed -i '/ssl_certificate_key/d' $config_file
                echo "SSL 已禁用。"
            fi
            systemctl reload nginx
            ;;
        4)
            echo "请输入网站域名："
            read domain
            if ! echo "$domain" | grep -qE '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
                echo "域名格式无效，请重新输入。"
                return
            fi
            config_file="/etc/nginx/sites-available/$domain"
            echo "server {" > $config_file
            echo "    listen 80;" >> $config_file
            echo "    server_name $domain;" >> $config_file
            echo "    return 301 https://\$host\$request_uri;" >> $config_file
            echo "}" >> $config_file
            systemctl reload nginx
            echo "HTTPS 重定向配置完成。"
            ;;
        5)
    # 删除网站配置
    echo "===== 已配置的网站列表 ====="
    ls /etc/nginx/sites-available/ 2>/dev/null || echo "无可用配置"
    echo "------------------------------"
    echo -n "请输入要删除的网站配置名称（留空取消）："
    read config_name
    [ -z "$config_name" ] && return

    # 确认操作
    echo -n "确认删除 $config_name 配置？(y/n): "
    read confirm
    if [ "$confirm" != "y" ]; then
        echo "操作已取消"
        return
    fi

    # 删除配置文件
    rm -f "/etc/nginx/sites-available/$config_name"
    rm -f "/etc/nginx/sites-enabled/$config_name"
    
    # 删除关联目录（仅静态网站）
    if [[ "$config_name" != proxy_* ]]; then
        rm -rf "/var/www/$config_name"
    fi
    
    nginx -t && systemctl reload nginx
    echo -e "\033[32m网站配置 $config_name 已删除\033[0m"
    ;;
        6)
            # 停用/启用网站
            echo "===== 网站配置状态 ====="
            echo "[已启用]"
            ls /etc/nginx/sites-enabled/ 2>/dev/null || echo "无已启用配置"
            echo "[未启用]"
            ls /etc/nginx/sites-available/ 2>/dev/null | grep -vxF "$(ls /etc/nginx/sites-enabled/ 2>/dev/null)" || echo "无未启用配置"
            echo "------------------------"
            echo -n "请输入要操作的配置名称（留空取消）："
            read config_name
            [ -z "$config_name" ] && return

            # 检查配置是否存在
            if [ ! -f "/etc/nginx/sites-available/$config_name" ]; then
                echo -e "\033[31m错误：配置 $config_name 不存在\033[0m"
                return
            fi

            echo "选择操作："
            echo "1. 停用网站"
            echo "2. 启用网站"
            read action_choice
            
            case $action_choice in
                1)
                    rm -f "/etc/nginx/sites-enabled/$config_name"
                    echo -e "\033[32m网站 $config_name 已停用\033[0m"
                    ;;
                2)
                    ln -sf "/etc/nginx/sites-available/$config_name" "/etc/nginx/sites-enabled/"
                    echo -e "\033[32m网站 $config_name 已启用\033[0m"
                    ;;
                *)
                    echo "无效选项"
                    return
                    ;;
            esac
            
            nginx -t && systemctl reload nginx
            ;;
        *)
            echo "无效选项"
            ;;
    esac
}

# 服务管理主菜单
manage_service() {
    echo "服务管理功能："
    echo "1. 一键启动所有服务"
    echo "2. 一键停止所有服务"
    echo "3. 单独管理服务"
    echo "4. 设置开机启动"
    echo "5. 禁用开机启动"  # 新增禁用开机启动选项
    echo "请选择操作："
    read srv_choice
    case $srv_choice in
        1)
            systemctl start nginx
            systemctl start redis-server
            pm2 start all
            echo "所有服务已启动。"
            ;;
        2)
            systemctl stop nginx
            systemctl stop redis-server
            pm2 stop all
            echo "所有服务已停止。"
            ;;
        3)
            echo "选择要管理的服务："
            echo "1. Nginx"
            echo "2. Redis"
            echo "3. pm2"
            read srv_sub_choice
            case $srv_sub_choice in
                1) manage_single_service "nginx" ;;
                2) manage_single_service "redis-server" ;;
                3) manage_pm2 ;;
                *) echo "无效选项，返回主菜单。" ;;
            esac
            ;;
        4)
            echo "选择要设置开机启动的服务："
            echo "1. Nginx"
            echo "2. Redis"
            read boot_choice
            case $boot_choice in
                1) systemctl enable nginx && echo "Nginx 已设置为开机启动。" ;;
                2) systemctl enable redis-server && echo "Redis 已设置为开机启动。" ;;
                *) echo "无效选项，返回主菜单。" ;;
            esac
            ;;
        5)
            echo "选择要禁用开机启动的服务："
            echo "1. Nginx"
            echo "2. Redis"
            read disable_choice
            case $disable_choice in
                1) systemctl disable nginx && echo "Nginx 开机启动已禁用。" ;;
                2) systemctl disable redis-server && echo "Redis 开机启动已禁用。" ;;
                *) echo "无效选项，返回主菜单。" ;;
            esac
            ;;
        *) echo "无效选项，返回主菜单。" ;;
    esac
}

# 管理单个服务（Nginx 或 Redis）
manage_single_service() {
    local service=$1
    echo "选择对 $service 的操作："
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    echo "4. 查看状态"
    read action_choice
    case $action_choice in
        1) systemctl start $service && echo "$service 已启动。" ;;
        2) systemctl stop $service && echo "$service 已停止。" ;;
        3) systemctl restart $service && echo "$service 已重启。" ;;
        4) systemctl status $service ;;
        *) echo "无效选项，返回主菜单。" ;;
    esac
}

# 管理 pm2 服务
manage_pm2() {
    echo "选择对 pm2 的操作："
    echo "1. 启动所有应用"
    echo "2. 停止所有应用"
    echo "3. 重启所有应用"
    echo "4. 查看应用状态"
    echo "5. 管理单个 pm2 应用"
    read pm2_choice
    case $pm2_choice in
        1) pm2 start all && echo "所有 pm2 应用已启动。" ;;
        2) pm2 stop all && echo "所有 pm2 应用已停止。" ;;
        3) pm2 restart all && echo "所有 pm2 应用已重启。" ;;
        4) pm2 list ;;
        5)
            echo "请输入 pm2 应用名称："
            read app_name
            echo "选择操作："
            echo "1. 启动"
            echo "2. 停止"
            echo "3. 重启"
            echo "4. 查看状态"
            read app_action
            case $app_action in
                1) pm2 start $app_name && echo "$app_name 已启动。" ;;
                2) pm2 stop $app_name && echo "$app_name 已停止。" ;;
                3) pm2 restart $app_name && echo "$app_name 已重启。" ;;
                4) pm2 show $app_name ;;
                *) echo "无效选项，返回主菜单。" ;;
            esac
            ;;
        *) echo "无效选项，返回主菜单。" ;;
    esac
}

# 交互式菜单
while true; do
    echo "===== Debian 12 服务器管理脚本 ====="
    echo "1. 组件管理"
    echo "2. SSL 证书管理"
    echo "3. 网站管理"
    echo "4. 服务管理"
    echo "5. 查看所有组件服务状态和配置信息"  # 新增选项
    echo "6. 退出"
    echo "请选择操作："
    read choice

    case $choice in
        1)
            echo "组件管理："
            echo "1. 一键安装所有组件"
            echo "2. 一键卸载所有组件"
            echo "3. 单独安装组件"
            echo "4. 单独卸载组件"
            read comp_choice
            case $comp_choice in
                1) install_all ;;
                2) uninstall_all ;;
                3)
                    echo "选择要安装的组件："
                    echo "1. Nginx"
                    echo "2. Node.js"
                    echo "3. pm2"
                    echo "4. SQLite"
                    echo "5. Redis"
                    echo "6. acme.sh"
                    read inst_choice
case $inst_choice in
    1) update_sources && install_nginx ;;
    2) update_sources && install_nodejs ;;
    3) update_sources && install_pm2 ;;
    4) update_sources && install_sqlite ;;
    5) update_sources && install_redis ;;
    6) install_acme ;;  # acme.sh 不需要 apt
    *) echo "无效选项，返回主菜单。" ;;
esac
                    ;;
                4)
                    echo "选择要卸载的组件："
                    echo "1. Nginx"
                    echo "2. Node.js"
                    echo "3. pm2"
                    echo "4. SQLite"
                    echo "5. Redis"
                    echo "6. acme.sh"
                    read uninst_choice
                    case $uninst_choice in
                        1) uninstall_nginx ;;
                        2) uninstall_nodejs ;;
                        3) uninstall_pm2 ;;
                        4) uninstall_sqlite ;;
                        5) uninstall_redis ;;
                        6) uninstall_acme ;;
                        *) echo "无效选项，返回主菜单。" ;;
                    esac
                    ;;
                *) echo "无效选项，返回主菜单。" ;;
            esac
            ;;
        2) manage_ssl ;;
        3) manage_website ;;
        4) manage_service ;;
        5) show_status ;;
        6) echo "退出脚本。" ; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
done
