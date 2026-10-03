# shellcheck shell=bash

function sync_hosts() {
    args=($@)
    num=$#
    for ((i = 0; i < num; i++)); do
        if remote_cp hosts "${args[${i}]}:/etc/hosts"; then
            success "${args[${i}]} hosts copied"
        fi
    done
}

function config_chrony() {
    local label=$1
    local directives=$2
    shift 2
    local host

    local command="chrony_conf=''
for f in /etc/chrony.conf /etc/chrony/chrony.conf; do
    if [ -f \"\$f\" ]; then chrony_conf=\$f; break; fi
done
if [ -z \"\$chrony_conf\" ]; then exit 0; fi
chrony_svc=''
for s in chronyd chrony; do
    if systemctl cat \"\${s}.service\" >/dev/null 2>&1; then chrony_svc=\$s; break; fi
done
if [ -z \"\$chrony_svc\" ]; then exit 0; fi
sed -i '/# BEGIN k8s-deploy/,/# END k8s-deploy/d' \"\$chrony_conf\"
sed -i -E 's/^[[:space:]]*(pool|server|allow|local)[[:space:]]/#&/' \"\$chrony_conf\"
cat >>\"\$chrony_conf\" <<EOF
# BEGIN k8s-deploy
${directives}
# END k8s-deploy
EOF
systemctl enable \"\$chrony_svc\"
systemctl restart \"\$chrony_svc\""

    for host in "$@"; do
        if remote_exec "${host}" "${command}"; then
            success "${host} ${label}"
        fi
    done
}

function config_system() {
    args=($@)
    num=$#
    ((num /= 2))

    # hostname
    for ((i = 0; i < num; i++)); do
        ((num2 = num + i))

        command="hostnamectl set-hostname ${args[${num2}]}"

        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set-hostname"
        fi

        if [ ! -f hosts ]; then
            touch hosts
            echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6" >>hosts
        fi

        sed -i -e "/^${args[${i}]}/d" hosts
        echo "${args[${i}]} ${args[${num2}]}" >>hosts
    done

    for ((i = 0; i < num; i++)); do
        if remote_cp "hosts" "${args[${i}]}:/etc/hosts"; then
            success "${args[${i}]} /etc/hosts"
        fi
    done

    # sysctl
    command="cat >/etc/sysctl.d/k8s.conf <<EOF
fs.inotify.max_user_watches = 65536
fs.file-max = 107374181600
vm.panic_on_oom = 0
vm.max_map_count = 262144
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.netfilter.nf_conntrack_max = 2621440
net.ipv4.ip_forward = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_timestamps = 0
net.core.somaxconn = 16384
EOF
sysctl --system"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} /etc/sysctl.d/k8s.conf"
        fi
    done

    # selinux
    command="if [ -f /etc/selinux/config ]; then
    if [ \$(getenforce) != \"Disabled\" ]; then
        setenforce 0 && sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    fi
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} selinux disabled"
        fi
    done

    # firewalld
    command="if systemctl list-units | grep firewalld; then
    systemctl disable firewalld --now
fi
if systemctl list-units | grep ufw; then
    ufw disable
    systemctl disable ufw --now
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} firewalld disabled"
        fi
    done

    # swapoff
    command="swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} /etc/fstab swapoff"
        fi
    done

    # nofile
    command="ulimit -SHn 65536
ulimit -SHu 65536
cat > /etc/security/limits.conf <<EOF
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
* soft memlock unlimited
* hard memlock unlimited
EOF"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} /etc/security/limits.conf"
        fi
    done

    command="if [ -f /etc/systemd/system.conf ]; then
    sed -i 's/.*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65536/' /etc/systemd/system.conf
elif [ -f /lib/systemd/system.conf ]; then
    sed -i 's/.*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65536/' /lib/systemd/system.conf
fi
systemctl daemon-reload"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set systemd nofile"
        fi
    done

    # timezone
    command="ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo 'Asia/Shanghai' >/etc/timezone"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} /etc/timezone Asia/Shanghai"
        fi
    done

    # ntp
    if [ ! -z "${ntp_server}" ]; then
        # 所有节点从外部 ntp 服务器同步
        config_chrony "set ntp client" "server ${ntp_server} iburst" "${args[@]:0:num}"
    else
        # 未指定外部 ntp 服务器时，node_ip[0] 作为集群内的时间源
        ntp_allow=""
        for ip in "${node_ip[@]}" "${addnode_ip[@]}"; do
            ntp_allow="${ntp_allow}allow ${ip}"$'\n'
        done
        config_chrony "set ntp master" "${ntp_allow}local stratum 10" "${node_ip[0]}"

        ntp_client=()
        for ((i = 0; i < num; i++)); do
            if [ "${args[${i}]}" != "${node_ip[0]}" ]; then
                ntp_client+=("${args[${i}]}")
            fi
        done

        if [ ${#ntp_client[@]} -gt 0 ]; then
            config_chrony "set ntp slave" "server ${node_ip[0]} iburst" "${ntp_client[@]}"
        fi
    fi

    # k8s modules
    command="cat >> /etc/modules-load.d/kubernetes.conf <<EOF
overlay
bridge
br_netfilter
nf_conntrack
nf_conntrack_ipv4
nf_nat
nf_nat_ipv4
nf_nat_redirect
nf_tables
nf_defrag_ipv4
nft_ct
nft_nat
nft_socket
nft_tproxy
nft_redir
ip_tables
ip_set
ip_set_hash_ip
iptable_mangle
iptable_nat
iptable_raw
x_tables
xt_REDIRECT
xt_connmark
xt_conntrack
xt_mark
xt_owner
xt_tcpudp
xt_multiport
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
ip_vs_lc
EOF
systemctl daemon-reload
systemctl restart systemd-modules-load.service"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set kubernetes kernel modules"
        fi
    done
}

