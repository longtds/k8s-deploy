#!/bin/bash
# shellcheck disable=SC2154,SC1091,SC2068,SC2086,SC2206

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
        success "download ${file_name}"
    else
        error "download ${file_name} failed"
    fi
}

function sync_image() {
    src_image="$1"
    dst_image="$2"

    if [ -n "${registry_proxy}" ]; then
        src_image=${registry_proxy}/${src_image}
    fi

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
        success "download ${file_path}"
    fi
}

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -i ${ssh_key} -p ${ssh_port} ${ssh_user}@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

function remote_cp() {
    local src=$1
    local dst=$2
    local mode=$3
    if ! scp ${mode} -i ${ssh_key} -P ${ssh_port} ${src} ${ssh_user}@${dst} >/dev/null 2>&1; then
        error "Copy ${src} to ${dst} failed"
    else
        success "Copy ${src} to ${dst}"
    fi
}

function check_pkg() {
    pkg_bin_list=(cfssl cfssljson etcd etcdctl kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl)
    pkg_yaml_list=(${coredns_file} ${localpath_file} ${metrics_file})
    pkg_image_list=(${registry_file} ${haproxy_file} ${image_file})
    pkg_tgz_list=(${nerdctl_file})
    pkg_bin_lastpath=${pkg_bin_path##*/}
    pkg_yaml_lastpath=${pkg_yaml_path##*/}
    pkg_image_lastpath=${pkg_image_path##*/}
    pkg_tgz_lastpath=${pkg_tgz_path##*/}

    for i in ${pkg_bin_list[@]}; do
        if [ ! -f ${pkg_path}/bin/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_bin_lastpath}/${i}
        fi
    done

    for i in ${pkg_yaml_list[@]}; do
        if [ ! -f ${pkg_path}/yaml/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_yaml_lastpath}/${i}
        fi
    done

    for i in ${pkg_image_list[@]}; do
        if [ ! -f ${pkg_path}/image/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_image_lastpath}/${i}
        fi
    done

    for i in ${pkg_tgz_list[@]}; do
        if [ ! -f ${pkg_path}/tgz/${i} ]; then
            note "not found ${i}, start downloading..."
            download_pkg ${pkg_tgz_lastpath}/${i}
        fi
    done
}

function check_node_pkg() {
    h2 "check node dependency"

    # kube-proxy/CNI 运行期强依赖的系统命令，缺失会导致安装"成功"但集群不可用
    node_bin_list=(iptables socat ipset conntrack)
    if [ "${kubeproxy_mode}" == "nftables" ]; then
        node_bin_list+=(nft)
    fi

    check_failed=0
    for host in "$@"; do
        command="for b in ${node_bin_list[*]}; do command -v \${b} >/dev/null 2>&1 || echo \${b}; done
for b in chronyc; do command -v \${b} >/dev/null 2>&1 || echo \"WARN:\${b}\"; done"

        if ! check_out=$(ssh -i ${ssh_key} -p ${ssh_port} ${ssh_user}@${host} "${command}" 2>/dev/null); then
            warn "${host} unreachable, check ssh/${ssh_key}"
            check_failed=1
            continue
        fi

        missing=$(echo "${check_out}" | grep -v '^WARN:' | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
        missing_warn=$(echo "${check_out}" | sed -n 's/^WARN://p' | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')

        if [ -n "${missing_warn}" ]; then
            warn "${host} missing optional: ${missing_warn} (time sync will be skipped)"
        fi

        if [ -n "${missing}" ]; then
            warn "${host} missing required: ${missing}"
            check_failed=1
        else
            success "${host} dependency ok"
        fi
    done

    if [ ${check_failed} -ne 0 ]; then
        note "install them first, e.g.
  rhel/anolis/kylin/openeuler:  dnf install -y nftables iptables-nft socat ipset conntrack-tools chrony
  debian/ubuntu:                apt install -y nftables iptables socat ipset conntrack chrony"
        error "node dependency check failed"
    fi
}

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
systemctl restart \"\$chrony_svc\"
systemctl enable \"\$chrony_svc\""

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
        if remote_cp "/etc/hosts" "${args[${i}]}:/etc/hosts"; then
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
    sed  's/.*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65536/' /etc/systemd/system.conf
elif [ -f /lib/systemd/system.conf ]; then
    sed  's/.*DefaultLimitNOFILE=.*/DefaultLimitNOFILE=65536/' /lib/systemd/system.conf
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
EOF
systemctl daemon-reload
systemctl restart systemd-modules-load.service"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} set kubernetes kernel modules"
        fi
    done
}

function config_certs() {
    if [ ! -d ${pki_path} ]; then
        mkdir -p ${pki_path}
    fi

    cd ${pki_path} || exit
    cat >ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "876000h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ],
        "expiry": "876000h"
      }
    }
  }
}
EOF

    cat >ca-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "k8s",
      "OU": "system"
    }
  ],
  "ca": {
    "expiry": "876000h"
 }
}
EOF

    cat >etcd-ca-csr.json <<EOF
{
  "CN": "etcd",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "etcd",
      "OU": "system"
    }
  ],
  "ca": {
    "expiry": "876000h"
 }
}
EOF

    chmod 755 -R ${pkg_path}/bin
    if ${pkg_path}/bin/cfssl gencert -initca ca-csr.json | ${pkg_path}/bin/cfssljson -bare ca; then
        success "k8s ca certificate created"
    fi
    if ${pkg_path}/bin/cfssl gencert -initca etcd-ca-csr.json | ${pkg_path}/bin/cfssljson -bare etcd-ca; then
        success "etcd ca certificate created"
    fi

    if [ ${#node_ip[@]} -ge 3 ]; then
        cat >etcd-csr.json <<EOF
{
  "CN": "etcd",
  "hosts": [
    "localhost",
    "127.0.0.1",
    "${node_ip[0]}",
    "${node_ip[1]}",
    "${node_ip[2]}"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "etcd",
      "OU": "etcd"
    }
  ]
}
EOF
    else
        cat >etcd-csr.json <<EOF
{
  "CN": "etcd",
  "hosts": [
    "localhost",
    "127.0.0.1",
    "${node_ip[0]}"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "etcd",
      "OU": "etcd"
    }
  ]
}
EOF
    fi

    if ${pkg_path}/bin/cfssl gencert -ca=etcd-ca.pem -ca-key=etcd-ca-key.pem -config=ca-config.json \
        -profile=kubernetes etcd-csr.json | ${pkg_path}/bin/cfssljson -bare etcd; then
        success "etcd server certificate created"
    fi

    if [ ${#node_ip[@]} -ge 3 ]; then
        cat >kube-apiserver-csr.json <<EOF
{
  "CN": "kubernetes",
  "hosts": [
    "localhost",
    "127.0.0.1",
    "${node_ip[0]}",
    "${node_ip[1]}",
    "${node_ip[2]}",
    "${node_hostname[0]}",
    "${node_hostname[1]}",
    "${node_hostname[2]}",
    "10.96.0.1",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF
    else
        cat >kube-apiserver-csr.json <<EOF
{
  "CN": "kubernetes",
  "hosts": [
    "localhost",
    "127.0.0.1",
    "${node_ip[0]}",
    "${node_hostname[0]}",
    "10.96.0.1",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF
    fi

    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-apiserver-csr.json | ${pkg_path}/bin/cfssljson -bare kube-apiserver; then
        success "kube-apiserver certificate created"
    fi

    cat >kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "Beijing", 
      "ST": "Beijing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF

    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-controller-manager-csr.json | ${pkg_path}/bin/cfssljson -bare kube-controller-manager; then
        success "kube-controller-manager certificate created"
    fi

    cat >kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "Beijing", 
      "ST": "Beijing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF

    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-scheduler-csr.json | ${pkg_path}/bin/cfssljson -bare kube-scheduler; then
        success "kube-scheduler certificate created"
    fi

    cat >admin-csr.json <<EOF
{
  "CN": "admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF
    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes admin-csr.json | ${pkg_path}/bin/cfssljson -bare admin; then
        success "kube admin certificate created"
    fi

    cat >kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "k8s",
      "OU": "system"
    }
  ]
}
EOF
    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-proxy-csr.json | ${pkg_path}/bin/cfssljson -bare kube-proxy; then
        success "kube-proxy certificate created"
    fi

    cat >proxy-client-csr.json <<EOF
{
  "CN": "aggregator",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "system:masters",
      "OU": "system"
    }
  ]
}
EOF
    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes proxy-client-csr.json | ${pkg_path}/bin/cfssljson -bare proxy-client; then
        success "proxy-client certificate created"
    fi

    if openssl genrsa -out sa.key 2048 >/dev/null 2>&1 && openssl rsa -in sa.key -pubout -out sa.pub; then
        success "kube service certificate created"
    fi

    cat >registry-csr.json <<EOF
{
  "CN": "registry",
  "hosts": [
    "${node_ip[0]}",
    "${node_ip[1]}",
    "${node_ip[2]}"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "Beijing",
      "L": "Beijing",
      "O": "registry",
      "OU": "registry"
    }
  ]
}
EOF
    if ${pkg_path}/bin/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes registry-csr.json | ${pkg_path}/bin/cfssljson -bare registry; then
        success "registry certificate created"
    fi

    cd ${run_path} || exit
}

function sync_certs() {
    args=($@)
    num=$#

    command1="mkdir -p ${install_path}/etc/pki"

    # Update ca-trust
    command2="if [ -d /etc/pki/ca-trust ]; then
    if update-ca-trust force-enable; then
        \cp -f ${install_path}/etc/pki/ca.pem /etc/pki/ca-trust/source/anchors/k8s-ca.pem
        \cp -f ${install_path}/etc/pki/etcd-ca.pem /etc/pki/ca-trust/source/anchors/etcd-ca.pem
        update-ca-trust extract
    else
        cat ${install_path}/etc/pki/ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        cat ${install_path}/etc/pki/etcd-ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    fi
fi
if [ -d /usr/local/share/ca-certificates ]; then
    if [ ! -f /usr/local/share/ca-certificates/k8s.crt ];then
        \cp -f ${install_path}/etc/pki/ca.pem /usr/local/share/ca-certificates/k8s.crt
        \cp -f ${install_path}/etc/pki/etcd-ca.pem /usr/local/share/ca-certificates/etcd.crt
        update-ca-certificates
    fi
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command1}"; then
            success "${args[${i}]} ${install_path}/etc created"
        fi

        if remote_cp "${pki_path}" "${args[${i}]}:${install_path}/etc" -r; then
            success "${args[${i}]} pki copied"
        fi

        if remote_exec ${args[${i}]} "${command2}"; then
            success "${args[${i}]} update-ca-trust"
        fi
    done

}

function sync_pkg() {
    args=($@)
    num=$#

    command1="mkdir -p ${install_path}/bin"
    command2="tar xf /tmp/${nerdctl_file} -C /usr/local/"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command1}"; then
            success "${args[${i}]} ${install_path}/bin created"
        fi

        if remote_cp "${pkg_path}/bin" "${args[${i}]}:${install_path}/" -r; then
            success "${args[${i}]} ${pkg_path}/bin copied"
        fi

        if remote_cp "${pkg_path}/image/${haproxy_file}" "${args[${i}]}:/tmp/${haproxy_file}"; then
            success "${args[${i}]} ${haproxy_file} copied"
        fi

        if remote_cp "${pkg_path}/tgz/${nerdctl_file}" "${args[${i}]}:/tmp/${nerdctl_file}"; then
            remote_exec ${args[${i}]} "${command2}"
            success "${args[${i}]} ${nerdctl_file} copied"
        fi
    done

    command3="mkdir -p ${data_path}/registry && tar xf /tmp/${image_file} -C ${data_path}/registry --strip-components=1"

    if remote_cp "${pkg_path}/image/${image_file}" "${master_node[0]}:/tmp/${image_file}" &&
        remote_exec ${master_node[0]} "${command3}"; then
        success "${master_node[0]} ${image_file} copied"
    fi

    if remote_cp "${pkg_path}/image/${registry_file}" "${master_node[0]}:/tmp/${registry_file}"; then
        success "${master_node[0]} ${registry_file} copied"
    fi
}
