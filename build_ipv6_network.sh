#!/bin/bash
# by https://github.com/spiritLHLS/lxc
# 2023.03.02

set -e

# 字体颜色
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# 检查 ip6tables jq lshw 是否存在，如果不存在则安装
if ! command -v ip6tables &> /dev/null
then
    apt-get update
    apt-get install -y ip6tables
fi
if ! command -v jq &> /dev/null
then
    apt-get update
    apt-get install -y jq
fi
if ! command -v lshw &> /dev/null
then
    apt-get update
    apt-get install -y lshw
fi

# 查询网卡
interface=$(lshw -C network | awk '/logical name:/{print $3}' | head -1)
_yellow "网卡 $interface"

# 获取指定LXC容器的内网IPV6
CONTAINER_NAME="$1"
CONTAINER_IPV6=$(lxc list $CONTAINER_NAME --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet6") | select(.scope=="global") | .address')
if [ -z "$CONTAINER_IPV6" ]; then
    _red "容器无内网IPV6地址，不进行自动映射"
    exit 1
fi
_blue "$CONTAINER_NAME 容器的内网IPV6地址为 $CONTAINER_IPV6"

# 获取母鸡子网
SUBNET=$(ip -6 addr show | grep -E 'inet6.*global' | awk '{print $2}' | awk -F'/' '{print $1}' | head -n 1 | cut -d ':' -f1-5):

# 检查是否存在 IPV6 
if [ -z "$SUBNET" ]; then
    _red "无 IPV6 子网，不进行自动映射"
    exit 1
fi
_blue "母鸡的IPV6子网地址为 $SUBNET"

# 寻找未使用的子网内的一个IPV6地址
for i in $(seq 1 65535); do
    IPV6="${SUBNET_PREFIX}:$i"
    if [[ $IPV6 == $CONTAINER_IPV6 ]]; then
        echo "1"
        continue
    fi
    if ip -6 addr show dev "$interface" | grep -q $IPV6; then
        echo "2"
        continue
    fi
    if ! ping6 -c1 -w1 -q $IPV6 &>/dev/null; then
        echo "3"
        if ! ip6tables -t nat -C PREROUTING -d $IPV6 -j DNAT --to-destination $CONTAINER_IPV6 &>/dev/null; then
            echo "4"
            _green IPV6
            break
        fi
    fi
    _yellow IPV6
done

# 检查是否找到未使用的 IPV6 地址
if [ -z "$IPV6" ]; then
    _red "无可用 IPV6 地址，不进行自动映射"
    exit 1
fi

# 映射 IPV6 地址到容器的私有 IPV6 地址
ip addr add "$IPV6"/64 dev "$interface"
ip6tables -t nat -A PREROUTING -d $IPV6 -j DNAT --to-destination $CONTAINER_IPV6

# 打印信息并测试是否通畅
if ping6 -c 3 $IPV6 &>/dev/null; then
    _green "$CONTAINER_NAME 容器的外网IPV6地址为 $IPV6"
else
    _red "映射失败"
    exit 1
fi

# 写入信息
echo "$CONTAINER_NAME $IPV6" >> "$1"