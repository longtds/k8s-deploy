#/bin/bash
# This is a collection of useful shell scripts
if [ -f config.ini ]; then
    source config.ini
else
    error "file config.ini not found."
fi

set +e
set -o noglob

bold=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 76)
white=$(tput setaf 7)
tan=$(tput setaf 202)
blue=$(tput setaf 25)

underline() {
    printf "${underline}${bold}%s${reset}\n" "$@"
}
h1() {
    printf "\n${underline}${bold}${blue}%s${reset}\n" "$@"
}
h2() {
    printf "\n${underline}${bold}${white}%s${reset}\n" "$@"
}
debug() {
    printf "${white}%s${reset}\n" "$@"
}
info() {
    printf "${white}➜ %s${reset}\n" "$@"
}
success() {
    printf "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S) ${green}✔ %s${reset}\n" "$@"
}
error() {
    printf "${red}✖ %s${reset}\n" "$@"
    exit 2
}
warn() {
    printf "${tan}➜ %s${reset}\n" "$@"
}
bold() {
    printf "${bold}%s${reset}\n" "$@"
}
note() {
    printf "\n${underline}${bold}${blue}Note:${reset} ${blue}%s${reset}\n" "$@"
}

set -e

function download() {
    file_url="$1"
    file_name="$2"

    if [ -f "${download_path}/${file_name}" ]; then
        note "${download_path}/${file_name} exists"
        return 0
    fi

    note "download ${file_url}"
    if curl -L --progress-bar "${file_url}" -o "${download_path}/${file_name}"; then
        success "download ${file_name} successfully"
    else
        error "download ${file_name} failed"
    fi
}

function sync_image() {
    src_image="$1"
    dst_image="$2"
    if docker pull --platform linux/${arch_name} "${src_image}"; then
        docker tag "${src_image}" "${dst_image}"
        if ! docker push "${dst_image}"; then
            error "push ${dst_image} failed"
        fi
    else
        error "pull ${src_image} failed"
    fi
}

function download_pkg() {
    file_path="$1"

    if [ ! -d ${pkg_path} ]; then mkdir -p ${pkg_path}; fi
    if ! curl -L --progress-bar "${pkg_url}/${file_path}" -o "${pkg_path}/${file_path}"; then
        error "download ${file_path} failed"
    else
        chmod 755 "${pkg_path}/${file_path}"
        success "download ${file_path} successfully"
    fi
}

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -i ${ssh_key} -p ${ssh_port} ${user}@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

function remote_cp() {
    local src=$1
    local dst=$2
    local mode=$3
    if ! scp ${mode} -i ${ssh_key} -P ${ssh_port} ${src} ${user}@${dst} >/dev/null 2>&1; then
        error "Copy ${src} to ${dst} failed"
    else
        success "Copy ${src} to ${dst} successfully"
    fi
}

function check_pkg() {
    pkg_bin_list=(cfssl cfssljson etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl nerdctl)
    pkg_yaml_list=(${flannel_file} ${coredns_file} ${localpath_file} ${metrics_file})
    pkg_image_list=(${registry_file} ${haproxy_file} ${image_file})
    pkg_tgz_list=(${containerd_file})
    pkg_bin_lastpath=${pkg_bin_path##*/}
    pkg_yaml_lastpath=${pkg_yaml_path##*/}
    pkg_image_lastpath=${pkg_image_path##*/}
    pkg_tgz_lastpath=${pkg_tgz_path##*/}

    for i in ${pkg_bin_list[@]}; do
        if [ ! -f ${pkg_bin_path}/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_bin_lastpath}/${i}
        fi
    done

    for i in ${pkg_yaml_list[@]}; do
        if [ ! -f ${pkg_yaml_path}/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_yaml_lastpath}/${i}
        fi
    done

    for i in ${pkg_image_list[@]}; do
        if [ ! -f ${pkg_image_path}/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_image_lastpath}/${i}
        fi
    done

    for i in ${pkg_tgz_list[@]}; do
        if [ ! -f ${pkg_tgz_path}/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_tgz_lastpath}/${i}
        fi
    done
}

function sync_hosts() {
    # Sync /etc/hosts
    args=($@)
    num=$#
    for ((i = 0; i < num; i++)); do
        if remote_cp "${hosts_path}" "${args[${i}]}:/etc/hosts"; then
            success "copy hosts to ${args[${i}]} successfully"
        fi
    done
}

function config_system() {
    args=($@)
    num=$#
    ((num /= 2))

    # Set hostname
    for ((i = 0; i < num; i++)); do
        ((num2 = num + i))

        command="hostnamectl set-hostname ${args[${num2}]}"

        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set hostname successfully"
        fi

        if [ ! -f ${hosts_path} ]; then
            touch ${hosts_path}
            echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6" >>${hosts_path}
        fi

        sed -i -e "/^${args[${i}]}/d" ${hosts_path}
        echo "${args[${i}]} ${args[${num2}]}" >>${hosts_path}
    done

    # Sync /etc/hosts
    for ((i = 0; i < num; i++)); do
        if remote_cp "/etc/hosts" "${args[${i}]}:/etc/hosts"; then
            success "copy hosts to ${args[${i}]} successfully"
        fi
    done

    # Set kernel parameters
    command="cat >/etc/sysctl.d/kubernetes.conf <<EOF
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
            success "${args[${i}]} set kernel successfully"
        fi
    done

    # Set SElinux
    command="if [ -f /etc/selinux/config ]; then
    if [ \$(getenforce) != \"Disabled\" ]; then
        setenforce 0 && sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    fi
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set selinux successfully"
        fi
    done

    # Set firewalld
    command="if systemctl list-units | grep firewalld; then
    systemctl disable firewalld --now
fi
if systemctl list-units | grep ufw; then
    ufw disable
    systemctl disable ufw --now
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set firewalld successfully"
        fi
    done

    # Set swap
    command="swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set swapoff successfully"
        fi
    done

    # Set nofile limits
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
            success "${args[${i}]} set nofile ulimit successfully"
        fi
    done

    # Set timezone
    command="ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo 'Asia/Shanghai' >/etc/timezone"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set timezone successfully"
        fi
    done

    # Set ntp
    command="if [ -f /etc/chrony.conf ]; then
    sed -i '/^#allow/c\allow 0.0.0.0/0' /etc/chrony.conf
    systemctl restart chronyd
    systemctl enable chronyd
fi"

    if remote_exec ${node_ip[0]} "${command}"; then
        success "${node_ip[0]} set ntp successfully"
    fi

    if [ $num -gt 1 ]; then
        command="if [ -f /etc/chrony.conf ]; then
    sed -i -e \"/^pool/c\server ${node_ip[0]} iburst\" /etc/chrony.conf
    systemctl restart chronyd
    systemctl enable chronyd
fi"

        for ((i = 1; i < num; i++)); do
            if remote_exec ${args[${i}]} "${command}"; then
                success "${args[${i}]} set ntp successfully"
            fi
        done
    fi

    # Set k8s modules
    command="cat >> /etc/modules-load.d/kubernetes.conf <<EOF 
overlay
br_netfilter
EOF
systemctl daemon-reload
systemctl restart systemd-modules-load.service"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set k8s modules successfully"
        fi
    done

    # Set ipvs
    if [ ${kubeproxy_mode} == "ipvs" ]; then
        command="cat >> /etc/modules-load.d/ipvs.conf <<EOF 
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
systemctl daemon-reload
systemctl restart systemd-modules-load.service"

        for ((i = 0; i < num; i++)); do
            if remote_exec ${args[${i}]} "${command}"; then
                success "${args[${i}]} set ipvs modules successfully"
            fi
        done
    fi
}
