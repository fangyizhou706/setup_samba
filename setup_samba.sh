#!/bin/bash

# 版本号文件
VERSION_FILE="samba_version.txt"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "1.0" > "$VERSION_FILE"
fi
CURRENT_VERSION=$(cat "$VERSION_FILE")
NEW_VERSION=$(echo "$CURRENT_VERSION + 0.01" | bc)
echo "$NEW_VERSION" > "$VERSION_FILE"

# 检查并安装figlet
check_install_figlet() {
    if ! command -v figlet &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y figlet
    fi
}

# 检查Samba安装状态
check_samba_install_status() {
    if dpkg -l | grep -qw samba; then
        echo "Samba已安装。"
        samba_version=$(dpkg -l | grep samba | head -n 1 | awk '{print $3}')
        echo "Samba版本: $samba_version"
    else
        echo "Samba未安装。"
    fi
}

# 检查Samba服务状态
check_samba_service_status() {
    if [ -x "$(command -v systemctl)" ]; then
        systemctl is-active --quiet smbd
    else
        service smbd status > /dev/null 2>&1
    fi
}

# 安装Samba
install_samba() {
    if dpkg -l | grep -qw samba; then
        read -p "Samba已经安装，是否覆盖现有配置文件? (y/n): " overwrite
        if [[ "$overwrite" != "y" ]]; then
            echo "安装取消。"
            return
        fi
    fi

    echo "安装Samba服务..."
    sudo apt-get update
    sudo apt-get install -y samba
    sudo systemctl start smbd
    sudo systemctl enable smbd
    add_samba_user
    echo "Samba服务安装完成。"
    echo "--------------------"
    echo "安装完成"
    echo "--------------------"
    restart_samba_service
}

# 卸载Samba
uninstall_samba() {
    echo "卸载Samba服务..."
    sudo systemctl stop smbd
    sudo systemctl disable smbd
    sudo apt-get remove --purge -y samba samba-common samba-common-bin
    sudo apt-get autoremove -y
    read -p "是否删除所有历史目录和配置文件? (y/n): " remove_all
    if [[ "$remove_all" == "y" ]]; then
        sudo rm -rf /etc/samba
        sudo rm -rf /var/lib/samba
    fi
    echo "Samba服务卸载完成。"
    echo "--------------------"
    echo "卸载完成"
    echo "--------------------"
    restart_samba_service
}

# 查看Samba服务状态
check_samba_status() {
    echo "查看服务状态"
    echo "--------------------"
    if check_samba_service_status; then
        echo "Samba服务正在运行。"
    else
        echo "Samba服务未启动。"
    fi
    samba_version=$(dpkg -l | grep samba | head -n 1 | awk '{print $3}')
    echo "Samba版本: $samba_version"
    echo "--------------------"
    echo "当前所有网卡的IP地址:"
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
    echo "访问方法: smb://<ip_address>"
    echo "--------------------"
}

# 修改Samba账户密码及权限
change_samba_password() {
    echo "修改Samba账户密码及权限"
    echo "--------------------"
    echo "1) 查看当前账户 ▶"
    echo "2) 添加账户 ▶"
    echo "3) 删除账户 ▶"
    echo "--------------------"
    echo "0) 返回主菜单"
    echo "--------------------"
    read -p "请输入选项: " change_option

    case $change_option in
        1) list_samba_users ;;
        2) add_samba_user ;;
        3) delete_samba_user_menu ;;
        0) return ;;
        *) echo "无效选项，请重新输入。" ;;
    esac
}

# 列出Samba用户
list_samba_users() {
    echo "查看当前账户"
    echo "--------------------"
    samba_config="/etc/samba/smb.conf"
    users=$(grep -E "^\[" "$samba_config" | sed 's/^\[\(.*\)\]$/\1/')

    counter=1
    echo "编号    账户名    路径                权限"
    for user in $users; do
        path=$(grep -A 4 "^\[$user\]" "$samba_config" | grep "path" | awk -F' = ' '{print $2}')
        read_only=$(grep -A 4 "^\[$user\]" "$samba_config" | grep "read only" | awk -F' = ' '{print $2}')
        if [ -z "$path" ]; then
            path="不存在"
        fi
        if [ "$read_only" == "yes" ]; then
            access="只读"
        else
            access="可写"
        fi
        echo "$counter     $user     $path     $access"
        counter=$((counter + 1))
    done
    echo "选择账户编号进行修改 (0返回):"
    read -p "请输入选项: " user_choice

    if [ "$user_choice" -eq 0 ]; then
        return
    fi

    chosen_user=$(echo "$users" | sed -n "${user_choice}p")
    if [ -z "$chosen_user" ]; then
        echo "无效选择，请重试。"
        return
    fi

    echo "选择修改类型:"
    echo "a) 修改密码"
    echo "b) 修改权限"
    echo "c) 删除账户"
    read -p "请输入选项: " modify_choice

    case $modify_choice in
        a) modify_samba_user_password "$chosen_user" ;;
        b) modify_samba_user_permissions "$chosen_user" ;;
        c) delete_samba_user "$chosen_user" ;;
        0) return ;;
        *) echo "无效选项，请重试。" ;;
    esac
}

# 修改Samba用户密码
modify_samba_user_password() {
    local samba_user="$1"
    read -sp "请输入新的Samba用户密码: " samba_pass
    echo

    echo -e "$samba_pass\n$samba_pass" | sudo smbpasswd -s "$samba_user"
    restart_samba_service

    echo "用户 $samba_user 的密码已更新。"
}

# 修改Samba用户权限
modify_samba_user_permissions() {
    local samba_user="$1"
    read -p "请输入新的共享目录路径 (默认 /home/$samba_user): " share_path
    read -p "请输入目录权限 (默认为可写, 输入 'ro' 设为只读): " access

    if [ -z "$share_path" ]; then
        share_path="/home/$samba_user"
    fi
    if [ -z "$access" ]; then
        access="rw"
    fi

    if [ ! -d "$share_path" ]; then
        echo "目录 $share_path 不存在，正在创建..."
        sudo mkdir -p "$share_path"
    fi
    sudo chmod 777 "$share_path"

    samba_config="/etc/samba/smb.conf"
    if grep -q "\[$samba_user\]" "$samba_config"; then
        echo "更新共享配置..."
        sudo sed -i "/^\[$samba_user\]/,+4d" "$samba_config"
        echo "[$samba_user]" | sudo tee -a "$samba_config" > /dev/null
        echo "   path = $share_path" | sudo tee -a "$samba_config" > /dev/null
        if [ "$access" == "ro" ]; then
            echo "   read only = yes" | sudo tee -a "$samba_config" > /dev/null
        else
            echo "   read only = no" | sudo tee -a "$samba_config" > /dev/null
        fi
        echo "   browsable = yes" | sudo tee -a "$samba_config" > /dev/null
        echo "   guest ok = no" | sudo tee -a "$samba_config" > /dev/null
        echo "   valid users = $samba_user" | sudo tee -a "$samba_config" > /dev/null
    fi

    restart_samba_service

    echo "用户 $samba_user 的权限已更新。"
}

# 添加Samba用户
add_samba_user() {
    echo "添加Samba用户"
    echo "--------------------"
    read -p "请输入Samba用户名: " samba_user
    read -sp "请输入Samba密码: " samba_pass
    echo
    read -p "请输入共享目录路径 (默认 /home/$samba_user): " share_path
    read -p "请输入目录权限 (默认为可写, 输入 'ro' 设为只读): " access

    if [ -z "$share_path" ]; then
        share_path="/home/$samba_user"
    fi
    if [ -z "$access" ]; then
        access="rw"
    fi

    if [ ! -d "$share_path" ]; then
        echo "目录 $share_path 不存在，正在创建..."
        sudo mkdir -p "$share_path"
    fi
    sudo chmod 777 "$share_path"

    samba_config="/etc/samba/smb.conf"
    if grep -q "\[$samba_user\]" "$samba_config"; then
        echo "用户 $samba_user 已存在，更新配置..."
        sudo sed -i "/^\[$samba_user\]/,+4d" "$samba_config"
    fi

    echo "[$samba_user]" | sudo tee -a "$samba_config" > /dev/null
    echo "   path = $share_path" | sudo tee -a "$samba_config" > /dev/null
    if [ "$access" == "ro" ]; then
        echo "   read only = yes" | sudo tee -a "$samba_config" > /dev/null
    else
        echo "   read only = no" | sudo tee -a "$samba_config" > /dev/null
    fi
    echo "   browsable = yes" | sudo tee -a "$samba_config" > /dev/null
    echo "   guest ok = no" | sudo tee -a "$samba_config" > /dev/null
    echo "   valid users = $samba_user" | sudo tee -a "$samba_config" > /dev/null

    echo -e "$samba_pass\n$samba_pass" | sudo smbpasswd -s -a "$samba_user"
    restart_samba_service

    echo "新用户 $samba_user 已添加。"
    echo "--------------------"
    list_samba_users
}

# 删除Samba用户菜单
delete_samba_user_menu() {
    echo "删除Samba用户"
    echo "--------------------"
    list_samba_users

    read -p "请输入要删除的账户编号 (0返回): " user_choice
    if [ "$user_choice" -eq 0 ]; then
        return
    fi

    if [[ ! "$user_choice" =~ ^[0-9]+$ ]]; then
        echo "无效选择，请重试。"
        return
    fi

    chosen_user=$(grep -E "^\[" "/etc/samba/smb.conf" | sed -n "${user_choice}p" | tr -d '[]')
    if [ -z "$chosen_user" ]; then
        echo "无效选择，请重试。"
        return
    fi

    delete_samba_user "$chosen_user"
    list_samba_users
}

# 删除Samba用户
delete_samba_user() {
    local samba_user="$1"
    read -p "确认删除用户 $samba_user? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "取消删除用户 $samba_user。"
        return
    fi

    sudo smbpasswd -x "$samba_user"
    sudo sed -i "/^\[$samba_user\]/,+4d" /etc/samba/smb.conf
    sudo rm -rf "/home/$samba_user"

    restart_samba_service

    echo "用户 $samba_user 已删除。"
}

# 重启Samba服务
restart_samba_service() {
    if [ -x "$(command -v systemctl)" ]; then
        sudo systemctl restart smbd
    else
        sudo service smbd restart
    fi
    echo "Samba服务已重启。"
    check_samba_status
}

# 主菜单
main_menu() {
    check_install_figlet

    while true; do
        clear
        figlet "Samba"
        echo "版本号: $NEW_VERSION"
        echo "--------------------"

        check_samba_install_status

        echo "--------------------"
        echo "1) 安装Samba"
        echo "2) 卸载Samba"
        echo "3) 查看服务状态"
        echo "4) 修改Samba账户密码及权限 ▶"
        echo "--------------------"
        echo "0) 退出"
        echo "--------------------"
        read -p "请输入选项: " option

        case $option in
            0) exit 0 ;;
            1) install_samba ;;
            2) uninstall_samba ;;
            3) check_samba_status ;;
            4) change_samba_password ;;
            *) echo "无效选项，请重新输入。" ;;
        esac

        echo "按任意键返回菜单..."
        read -n 1 -s
    done
}

main_menu
