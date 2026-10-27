#!/bin/bash

# ==============================================================================
# PHP Version Manager - Ubuntu (Linux / APT Edition)
# 
# 1. 将加载命令写入你的 zsh 配置文件
# echo '[[ -s "$HOME/.pvm/pvm.sh" ]] && source "$HOME/.pvm/pvm.sh"' >> ~/.zshrc
# 
# 2. 让配置立即在当前终端生效
# source ~/.zshrc
# ==============================================================================

CORE_EXTENSIONS=("curl" "mbstring" "xml" "zip" "gd" "intl" "bcmath" "opcache" "readline" "mysql" "pgsql" "sqlite3" "redis")

init() {
    echo "正在检查 PHP PPA 源..."
    if ! grep -q "^deb.*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/bin/null; then
        echo "未检测到 ondrej/php 源，正在添加..."
        sudo apt update
        sudo apt install -y software-properties-common
        sudo LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y
        sudo apt update
        echo "PPA 源添加成功！"
    else
        echo "ondrej/php 源已存在，无需重复添加。"
    fi
}

list_available() {
    apt-cache search --names-only '^php[0-9]+\.[0-9]+$' | awk '{print $1}' | sort -V
}

list_installed() {
    local current_active=""
    if which php >/dev/null 2>&1; then
        current_active=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
    fi

    local installed_vers
    installed_vers=$(update-alternatives --list php 2>/bin/null | grep -oE 'php[0-9]+\.[0-9]+' | sed 's/php//' | sort -uV)

    if [ -z "$installed_vers" ]; then
        echo "提示: 未检测到本地已安装的 PHP 版本。"
        return 0
    fi

    echo "已安装的 PHP 版本："
    
    while read -r ver; do
        if [ "$ver" = "$current_active" ]; then
            echo -e "->  v${ver} \033[32m(Currently active)\033[0m"
        else
            echo "    v${ver}"
        fi
    done <<< "$installed_vers"
}

install_version() {
    local version=$1
    if [ -z "$version" ]; then
        echo "错误: 请指定要安装的版本 (例如: pvm install 8.4)"
        return 1
    fi

    local available_pkgs
    available_pkgs=$(apt-cache pkgnames "php${version}-" 2>/dev/null)

    echo "开始安装 PHP $version 基础环境..."
    sudo apt install -y "php${version}-cli" "php${version}-common"

    local php_bin
    php_bin=$(which "php${version}" 2>/dev/null)

    if [ -z "$php_bin" ] || [ ! -x "$php_bin" ]; then
        if [ -x "/usr/bin/php${version}" ]; then
            php_bin="/usr/bin/php${version}"
            echo "PHP $version 已安装..."
        else
            echo "错误: 未找到 PHP $version 的可执行文件, 安装可能失败！"
            return 1
        fi
    fi

    local build_in_exts
    build_in_exts=$("$php_bin" -m | tr '[:upper:]' '[:lower:]')

    local install_exts=()
    for ext in "${CORE_EXTENSIONS[@]}"; do
        local ext_name="php${version}-${ext}"

        if echo "$build_in_exts" | grep -qFx "$ext_name"; then
            continue
        fi

        if echo "$available_pkgs" | grep -qFx "$ext_name"; then
            install_exts+=("$ext_name")
        else
            echo ":: 拓展 $ext_name 在当前源不存在, 已跳过"
        fi
    done
    
    if [ ${#install_exts[@]} -gt 0 ]; then
        echo "开始安装 PHP${version} 拓展: ${install_exts[*]}..."
        sudo apt install -y "${install_exts[@]}"
    else
        echo "未安装额外拓展"
    fi

    local composer_path=$(type -p composer 2>/dev/null)
    if [ -z "$composer_path" ] || [[ "$composer_path" =~ /mnt/[a-z]/ ]]; then
        read -r -p "是否现在安装 Composer 依赖包管理器？(y/n): " input
        case "$input" in
            [yY][eE][sS]|[yY])
                install_composer
                ;;
            *)
                echo "已跳过 Composer 安装，你可以后续通过 pvm install-composer 命令安装。"
                ;;
        esac
    fi
    
    echo "PHP $version 及其可用拓展安装完成！"
}

install_composer() {
    local php_bin=$(which php 2>/dev/null)
    local composer_path=$(type -p composer 2>/dev/null)

    if [ ! -z "$composer_path" ] && [[ ! "$composer_path" =~ /mnt/[a-z]/ ]]; then
        echo "Composer 已安装"
        return 1
    fi

    if [ -z "$php_bin" ] || [ ! -x "$php_bin" ]; then
        echo "错误: 未找到可用的 PHP 环境, 请先安装 PHP"
        return 1
    fi

    echo "正在全局安装 Composer..."
    cd "$HOME" || return 1
    "$php_bin" -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    "$php_bin" composer-setup.php
    "$php_bin" -r "unlink('composer-setup.php');"
    sudo mv composer.phar /usr/local/bin/composer

    echo "🎉 Composer 安装成功！当前版本: $(composer --version | head -n 1)"
}

uninstall_version() {
    local version=$1
    if [ -z "$version" ]; then
        echo "错误: 请指定要卸载的版本 (例如: pvm uninstall 8.4)"
        return 1
    fi

    if ! update-alternatives --list php 2>/bin/null | grep -q "php${version}"; then
        echo "错误: 本地未检测到 PHP $version，无需卸载。"
        return 1
    fi

    read -p "确定要彻底卸载 PHP $version 及其所有扩展吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "操作已取消。"
        return 0
    fi

    echo "正在卸载 PHP $version 及相关组件..."
    sudo apt purge -y "php${version}*"
    sudo apt autoremove -y

    echo "PHP $version 卸载完成。"

    if ! which php >/dev/null 2>&1; then
        echo "提示: 当前激活的 PHP 版本已被卸载。"
        local remaining_ver=$(update-alternatives --list php 2>/bin/null | head -n 1 | grep -oE 'php[0-9]+\.[0-9]+')
        if [ -not -z "$remaining_ver" ]; then
            echo "正在自动切换到其他可用版本: $remaining_ver"
            switch_version "$remaining_ver"
        else
            echo "系统已无其他可用的 PHP 版本。"
        fi
    fi
}

switch_version() {
    local version=$1
    if [ -z "$version" ]; then
        echo "错误: 请指定要切换的目标版本 (例如: pvm use 8.4)"
        return 1
    fi

    if ! update-alternatives --list php 2>/bin/null | grep -q "php${version}"; then
        echo "错误: PHP $version 尚未安装，请先运行 pvm install $version"
        return 1
    fi

    echo "正在切换系统 PHP 版本至 $version..."
    sudo update-alternatives --set php "/usr/bin/php${version}"
    
    if update-alternatives --list php-config >/dev/null 2>&1; then
        sudo update-alternatives --set php-config "/usr/bin/php-config${version}" 2>/dev/null
    fi
    if update-alternatives --list phpize >/dev/null 2>&1; then
        sudo update-alternatives --set phpize "/usr/bin/phpize${version}" 2>/dev/null
    fi

    echo "切换成功！当前版本信息："
    php -v
}

show_help() {
    echo "PHP Version Manager (PVM)"
    echo "用法:"
    echo "  pvm init                - 初始化并检查添加 PPA 源"
    echo "  pvm list-remote         - 列出源中所有可安装的 PHP 版本"
    echo "  pvm list                - 列出本地已安装的 PHP 版本"
    echo "  pvm install <ver>       - 安装指定版本的 PHP 及其拓展"
    echo "  pvm uninstall <ver>     - 卸载指定版本的 PHP 及其拓展"
    echo "  pvm use <ver>           - 切换到指定版本的 PHP"
    echo "  pvm install-composer    - 安装 Composer"
}

pvm() {
    case "$1" in
        init)               init ;;
        list-remote)        list_available ;;
        list)               list_installed ;;
        install)            install_version "$2" ;;
        uninstall)          uninstall_version "$2" ;;
        use)                switch_version "$2" ;;
        install-composer)   install_composer ;;
        *)                  show_help ;;
    esac
}
