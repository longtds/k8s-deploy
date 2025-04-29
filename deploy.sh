#!/bin/bash
# shellcheck disable=SC2087,SC2086,SC2206,SC2016,SC1091,SC2154

if [ -f utils.sh ]; then
    source utils.sh
else
    echo "file utils.sh not found."
    exit 1
fi

if [ -f config.ini ]; then
    source config.ini
else
    error "file config.ini not found."
fi

if [ ${#node_ip[@]} -ge 3 ]; then
    master_node=(${node_ip[0]} ${node_ip[1]} ${node_ip[2]})
    apiserver_url=https://127.0.0.1:8443
else
    master_node=(${node_ip[0]})
    apiserver_url=https://${master_node[0]}:6443
fi

node_ip_hostname=(${node_ip[@]} ${node_hostname[@]})
addnode_ip_hostname=(${addnode_ip[@]} ${addnode_hostname[@]})
registry=${node_ip[0]}:5000

function remote_exec() {
    local host=$1
    local cmd=$2
    if ! ssh -p ${ssh_port} ${user}@${host} "${cmd}" >/dev/null 2>&1; then
        error "Execute command failed on ${host}: ${cmd}"
    fi
}

function remote_cp() {
    local src=$1
    local dst=$2
    if ! scp -P ${ssh_port} ${src} ${user}@${dst} >/dev/null 2>&1; then
        error "Copy ${src} to ${dst} failed"
    fi
}

function sync_hosts() {
    # Sync /etc/hosts
    args=($@)
    num=$#
    for ((i = 0; i < num; i++)); do
        if remote_cp "/etc/hosts" "${args[${i}]}:/etc/hosts"; then
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

        sed -i -e "/^${args[${i}]}/d" /etc/hosts
        echo "${args[${i}]} ${args[${num2}]}" >>/etc/hosts
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
    command="ulimit -SHn 655360
ulimit -SHu 65536
cat > /etc/security/limits.conf <<EOF
* soft nofile 655360
* hard nofile 655360
* soft nproc 65536
* hard nproc 65536
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
ip_vs_lc
ip_vs_wlc
ip_vs_rr
ip_vs_wrr
ip_vs_lblc
ip_vs_lblcr
ip_vs_dh
ip_vs_sh
ip_vs_fo
ip_vs_nq
ip_vs_sed
ip_vs_ftp
ip_vs_sh
nf_conntrack
ip_tables
ip_set
xt_set
ipt_set
ipt_rpfilter
ipt_REJECT
ipip
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

function download_pkg() {
    file_name="$1"

    if [ ! -d ${pkg_path} ]; then mkdir -p ${pkg_path}; fi
    curl -L --progress-bar "${pkg_url}/${file_name}" -o "${pkg_path}/${file_name}"
    return $?
}

function config_certs() {
    if [ ! -f ${pkg_path}/${cfssl_pkg} ]; then
        note "not found ${cfssl_pkg}, start downloading ..."
        download_pkg ${cfssl_pkg}
    fi

    if [ ! -d ${bin_path} ]; then mkdir -p ${bin_path}; fi

    if tar xf ${pkg_path}/${cfssl_pkg} -C ${bin_path}; then
        success "decompress ${pkg_path}/${cfssl_pkg} successfully"
    fi

    if [ ! -d ${run_path}/pki ]; then
        mkdir -p ${run_path}/pki
    fi

    cd ${run_path}/pki
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

    chmod 755 -R ${run_path}/pkg
    if ${bin_path}/cfssl gencert -initca ca-csr.json | ${bin_path}/cfssljson -bare ca; then
        success "create k8s ca certificate successfully"
    fi
    if ${bin_path}/cfssl gencert -initca etcd-ca-csr.json | ${bin_path}/cfssljson -bare etcd-ca; then
        success "create etcd ca certificate successfully"
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

    if ${bin_path}/cfssl gencert -ca=etcd-ca.pem -ca-key=etcd-ca-key.pem -config=ca-config.json \
        -profile=kubernetes etcd-csr.json | ${bin_path}/cfssljson -bare etcd; then
        success "create etcd server certificate successfully"
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

    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-apiserver-csr.json | ${bin_path}/cfssljson -bare kube-apiserver; then
        success "create kube-apiserver certificate successfully"
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

    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-controller-manager-csr.json | ${bin_path}/cfssljson -bare kube-controller-manager; then
        success "create kube-controller-manager certificate successfully"
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

    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-scheduler-csr.json | ${bin_path}/cfssljson -bare kube-scheduler; then
        success "create kube-scheduler certificate successfully"
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
    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes admin-csr.json | ${bin_path}/cfssljson -bare admin; then
        success "create kube admin certificate successfully"
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
    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes kube-proxy-csr.json | ${bin_path}/cfssljson -bare kube-proxy; then
        success "create kube-proxy certificate successfully"
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
    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes proxy-client-csr.json | ${bin_path}/cfssljson -bare proxy-client; then
        success "create proxy-client certificate successfully"
    fi

    if openssl genrsa -out sa.key 2048 >/dev/null 2>&1 && openssl rsa -in sa.key -pubout -out sa.pub; then
        success "create kube service certificate successfully"
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
    if ${bin_path}/cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
        -profile=kubernetes registry-csr.json | ${bin_path}/cfssljson -bare registry; then
        success "create registry certificate successfully"
    fi

    if [ -f ${pkg_path:?}/${cert_file} ]; then rm ${pkg_path:?}/${cert_file} -rf; fi

    cd ${run_path} && tar zcf ${pkg_path}/${cert_file} pki
}

function sync_pkg() {
    args=($@)
    num=$#

    if [ ! -f ${pkg_path}/${cert_file} ]; then config_certs; fi

    for ((i = 0; i < num; i++)); do
        if remote_cp "${pkg_path}/${cert_file}" "${args[${i}]}:/tmp/${cert_file}"; then
            success "sync ${cert_file} to ${args[${i}]} successfully"
        fi

        command="mkdir -p ${cfg_path}
mkdir -p ${bin_path}
tar xf /tmp/${cert_file} -C ${cfg_path}
if [ -d /etc/pki/ca-trust ]; then
    if update-ca-trust force-enable; then
        \cp -f ${cfg_path}/pki/ca.pem /etc/pki/ca-trust/source/anchors/k8s-ca.pem
        \cp -f ${cfg_path}/pki/etcd-ca.pem /etc/pki/ca-trust/source/anchors/etcd-ca.pem
        update-ca-trust extract
    else
        cat ${cfg_path}/pki/ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        cat ${cfg_path}/pki/etcd-ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    fi
fi
if [ -d /usr/local/share/ca-certificates ]; then
    if [ ! -f /usr/local/share/ca-certificates/k8s.crt ];then
        \cp -f ${cfg_path}/pki/ca.pem /usr/local/share/ca-certificates/k8s.crt
        \cp -f ${cfg_path}/pki/etcd-ca.pem /usr/local/share/ca-certificates/etcd.crt
        update-ca-certificates
    fi
fi"
        if remote_exec ${args[${i}]} "${command}"; then
            success "update-ca-trust on ${args[${i}]} successfully"
        fi

        if [[ ${master_node[*]} =~ ${args[${i}]} ]]; then
            if [ ! -f ${pkg_path}/${etcd_pkg} ]; then
                note "not found ${etcd_pkg}, start downloading ..."
                download_pkg ${etcd_pkg}
            fi

            command="if [ ! -d ${bin_path} ]; then mkdir -p ${bin_path}; fi
tar xf /tmp/${etcd_pkg} -C ${bin_path}"
            if remote_cp "${pkg_path}/${etcd_pkg}" "${args[${i}]}:/tmp/${etcd_pkg}" &&
                remote_exec ${args[${i}]} "${command}"; then
                success "sync ${etcd_pkg} to ${args[${i}]} successfully"
            fi
        fi

        if [ ! -f ${pkg_path}/${kubernetes_pkg} ]; then
            note "not found ${kubernetes_pkg}, start downloading ..."
            download_pkg ${kubernetes_pkg}
        fi

        command="if [ ! -d ${bin_path} ]; then mkdir -p ${bin_path}; fi
tar xf /tmp/${kubernetes_pkg} -C ${bin_path}"
        if remote_cp "${pkg_path}/${kubernetes_pkg}" "${args[${i}]}:/tmp/${kubernetes_pkg}" &&
            remote_exec ${args[${i}]} "${command}"; then
            success "sync ${kubernetes_pkg} to ${args[${i}]} successfully"
        fi

        if [ ! -f ${pkg_path}/${haproxy_pkg} ]; then
            note "not found ${haproxy_pkg}, start downloading ..."
            download_file ${haproxy_pkg}
        fi

        if remote_cp "${pkg_path}/${haproxy_pkg}" "${args[${i}]}:/tmp/${haproxy_pkg}"; then
            success "sync ${haproxy_pkg} to ${args[${i}]} successfully"
        fi

        if [ ! -f ${pkg_path}/${containerd_pkg} ]; then
            note "not found ${containerd_pkg}, start downloading ..."
            download_pkg ${containerd_pkg}
        fi

        command="tar xf /tmp/${containerd_pkg} -C /
rm /etc/cni/net.d/10-containerd-net.conflist -rf"
        if remote_cp "${pkg_path}/${containerd_pkg}" "${args[${i}]}:/tmp/${containerd_pkg}" &&
            remote_exec ${args[${i}]} "${command}"; then
            success "sync ${containerd_pkg} to ${args[${i}]} successfully"
        fi

        if [ ! -f ${pkg_path}/${nerdctl_pkg} ]; then
            note "not found ${nerdctl_pkg}, start downloading ..."
            download_pkg ${nerdctl_pkg}
        fi

        command="tar xf /tmp/${nerdctl_pkg} -C ${bin_path}"
        if remote_cp "${pkg_path}/${nerdctl_pkg}" "${args[${i}]}:/tmp/${nerdctl_pkg}" &&
            remote_exec ${args[${i}]} "${command}"; then
            success "sync ${nerdctl_pkg} to ${args[${i}]} successfully"
        fi

        if [[ ${master_node[*]} =~ ${args[${i}]} ]]; then
            if [ ! -f ${pkg_path}/${image_pkg} ]; then
                note "not found ${image_pkg}, start downloading ..."
                download_pkg ${image_pkg}
            fi

            command="tar xf /tmp/${image_pkg} -C ${base_path}"
            if remote_cp "${pkg_path}/${image_pkg}" "${args[${i}]}:/tmp/${image_pkg}" &&
                remote_exec ${args[${i}]} "${command}"; then
                success "sync ${image_pkg} to ${args[${i}]} successfully"
            fi

            if [ ! -f ${pkg_path}/${registry_pkg} ]; then
                note "not found ${registry_pkg}, start downloading ..."
                download_pkg ${registry_pkg}
            fi

            if remote_cp "${pkg_path}/${registry_pkg}" "${args[${i}]}:/tmp/${registry_pkg}"; then
                success "sync ${registry_pkg} to ${args[${i}]} successfully"
            fi
        fi
    done
}

function config_etcd() {
    nm=0

    if [ ${#master_node[@]} -eq 3 ]; then
        for i in "${master_node[@]}"; do
            command="cat > /usr/lib/systemd/system/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target

[Service]
Type=notify
ExecStart=${bin_path}/etcd --name=${node_hostname[${nm}]} \
--data-dir=${base_path}/etcd \
--wal-dir=${base_path}/etcd/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380,${node_hostname[1]}=https://${node_ip[1]}:2380,${node_hostname[2]}=https://${node_ip[2]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${cfg_path}/pki/etcd.pem \
--key-file=${cfg_path}/pki/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${cfg_path}/pki/etcd-ca.pem \
--peer-cert-file=${cfg_path}/pki/etcd.pem \
--peer-key-file=${cfg_path}/pki/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${cfg_path}/pki/etcd-ca.pem \
--auto-compaction-mode=periodic \
--auto-compaction-retention=1 \
--max-request-bytes=33554432 \
--quota-backend-bytes=6442450944 \
--heartbeat-interval=250 \
--election-timeout=2000 \
--cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
Alias=etcd3.service

EOF
systemctl daemon-reload
systemctl restart etcd
systemctl enable etcd"

            if remote_exec ${i} "${command}"; then
                success "start etcd service on ${i} successfully"
            fi
            ((nm = nm + 1))
        done
    else
        for i in "${master_node[@]}"; do
            command="cat > /usr/lib/systemd/system/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target

[Service]
Type=notify
ExecStart=${bin_path}/etcd --name=${node_hostname[${nm}]} \
--data-dir=${base_path}/etcd \
--wal-dir=${base_path}/etcd/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${cfg_path}/pki/etcd.pem \
--key-file=${cfg_path}/pki/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${cfg_path}/pki/etcd-ca.pem \
--peer-cert-file=${cfg_path}/pki/etcd.pem \
--peer-key-file=${cfg_path}/pki/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${cfg_path}/pki/etcd-ca.pem \
--auto-compaction-mode=periodic \
--auto-compaction-retention=1 \
--max-request-bytes=33554432 \
--quota-backend-bytes=6442450944 \
--heartbeat-interval=250 \
--election-timeout=2000 \
--cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
Alias=etcd3.service

EOF
systemctl daemon-reload
systemctl restart etcd
systemctl enable etcd"

            if remote_exec ${i} "${command}"; then
                success "start etcd service on ${i} successfully"
            fi
        done
    fi

    if [ ${#master_node[@]} -eq 3 ]; then
        command="ETCDCTL_API=3 ${bin_path}/etcdctl \
--cacert=${cfg_path}/pki/etcd-ca.pem \
--cert=${cfg_path}/pki/etcd.pem \
--key=${cfg_path}/pki/etcd-key.pem \
--endpoints="https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379" \
endpoint status --write-out=table"

        if remote_exec ${node_ip[0]} "${command}"; then
            success "start etcd cluster successfully"
        fi
    else
        command="ETCDCTL_API=3 ${bin_path}/etcdctl \
--cacert=${cfg_path}/pki/etcd-ca.pem \
--cert=${cfg_path}/pki/etcd.pem \
--key=${cfg_path}/pki/etcd-key.pem \
--endpoints="https://${node_ip[0]}:2379" \
endpoint status --write-out=table"

        if remote_exec ${node_ip[0]} "${command}"; then
            success "start etcd cluster successfully"
        fi
    fi
}

function config_apiserver() {
    if [ ${#master_node[@]} -eq 3 ]; then
        for i in "${master_node[@]}"; do
            command="cat > ${cfg_path}/token.csv <<EOF
a5587b0a00bbbd5ead752f7074b4f644,kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${bin_path}/kube-apiserver \
--apiserver-count=3 \
--etcd-servers=https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379 \
--etcd-cafile=${cfg_path}/pki/etcd-ca.pem \
--etcd-certfile=${cfg_path}/pki/etcd.pem \
--etcd-keyfile=${cfg_path}/pki/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction,DefaultTolerationSeconds,DefaultStorageClass \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${cfg_path}/token.csv \
--kubelet-client-certificate=${cfg_path}/pki/kube-apiserver.pem \
--kubelet-client-key=${cfg_path}/pki/kube-apiserver-key.pem \
--tls-cert-file=${cfg_path}/pki/kube-apiserver.pem  \
--tls-private-key-file=${cfg_path}/pki/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${cfg_path}/pki/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${cfg_path}/pki/sa.key \
--service-account-key-file=${cfg_path}/pki/sa.pub \
--proxy-client-cert-file=${cfg_path}/pki/kube-apiserver.pem \
--proxy-client-key-file=${cfg_path}/pki/kube-apiserver-key.pem \
--requestheader-client-ca-file=${cfg_path}/pki/ca.pem \
--requestheader-allowed-names=kubernetes \
--requestheader-extra-headers-prefix=X-Remote-Extra- \
--requestheader-group-headers=X-Remote-Group \
--requestheader-username-headers=X-Remote-User \
--enable-aggregator-routing=true \
--audit-log-maxage=15 \
--audit-log-maxbackup=3 \
--audit-log-maxsize=10 \
--audit-log-path=/var/log/kubernetes/apiserver-audit.log \
--delete-collection-workers=10

Restart=on-failure
RestartSec=10s
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-apiserver
systemctl enable kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "start kube-apiserver service on ${i} successfully"
            fi
        done
    else
        for i in "${master_node[@]}"; do
            command="cat > ${cfg_path}/token.csv <<EOF
a5587b0a00bbbd5ead752f7074b4f644,kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${bin_path}/kube-apiserver \
--apiserver-count=1 \
--etcd-servers=https://${node_ip[0]}:2379 \
--etcd-cafile=${cfg_path}/pki/etcd-ca.pem \
--etcd-certfile=${cfg_path}/pki/etcd.pem \
--etcd-keyfile=${cfg_path}/pki/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${cfg_path}/token.csv \
--kubelet-client-certificate=${cfg_path}/pki/kube-apiserver.pem \
--kubelet-client-key=${cfg_path}/pki/kube-apiserver-key.pem \
--tls-cert-file=${cfg_path}/pki/kube-apiserver.pem  \
--tls-private-key-file=${cfg_path}/pki/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${cfg_path}/pki/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${cfg_path}/pki/sa.key \
--service-account-key-file=${cfg_path}/pki/sa.pub \
--proxy-client-cert-file=${cfg_path}/pki/kube-apiserver.pem \
--proxy-client-key-file=${cfg_path}/pki/kube-apiserver-key.pem \
--requestheader-client-ca-file=${cfg_path}/pki/ca.pem \
--requestheader-allowed-names=kubernetes \
--requestheader-extra-headers-prefix=X-Remote-Extra- \
--requestheader-group-headers=X-Remote-Group \
--requestheader-username-headers=X-Remote-User \
--enable-aggregator-routing=true \
--audit-log-maxage=30 \
--audit-log-maxbackup=3 \
--audit-log-maxsize=100 \
--audit-log-path=/var/log/kubernetes/apiserver-audit.log \
--delete-collection-workers=10

Restart=on-failure
RestartSec=10s
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-apiserver
systemctl enable kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "start kube-apiserver service on ${i} successfully"
            fi
        done
    fi
}

function config_containerd() {
    args=($@)
    num=$#

    command="/usr/local/bin/containerd config default > /tmp/config.toml"

    if remote_exec ${args[0]} "${command}"; then
        if scp -P ${ssh_port} ${user}@${args[0]}:/tmp/config.toml /tmp/config.toml; then
            sed -i -e "s#registry.k8s.io/pause:3.8#${registry}/k8s/pause:3.8#g" \
                -e "s#SystemdCgroup = false#SystemdCgroup = true#g" \
                -e "s#device_ownership_from_security_context = false#device_ownership_from_security_context = true#g" \
                -e "s#      config_path = \"\"#      config_path = \"/etc/containerd/certs.d\"#" /tmp/config.toml
            echo -e "server = \"https://${registry}\"\n\n[host.\"https://${registry}\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  ca = \"${cfg_path}/pki/ca.pem\"" >/tmp/hosts.toml
        fi
    fi

    command="systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd"

    for ((i = 0; i < num; i++)); do
        if
            remote_exec ${args[${i}]} "mkdir -p /etc/containerd/certs.d/${registry}" &&
                remote_cp /tmp/config.toml ${args[${i}]}:/etc/containerd/config.toml &&
                remote_cp /tmp/hosts.toml ${args[${i}]}:/etc/containerd/certs.d/${registry}/hosts.toml
        then
            if remote_exec ${args[${i}]} "${command}"; then
                success "start containerd service on ${args[${i}]} successfully"
            fi
        fi
    done
}

function config_apiproxy() {
    args=($@)
    num=$#

    if [ ${#master_node[@]} -eq 3 ]; then
        command="if ! ${bin_path}/nerdctl ps |grep apiproxy; then
    ${bin_path}/nerdctl load -i /tmp/${haproxy_pkg}
    cat > ${cfg_path}/haproxy.cfg <<EOF
global
    maxconn 2000
    log 127.0.0.1 local0 err
    stats timeout 30s

defaults
    log global
    mode http
    option httplog
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    timeout http-request 15s
    timeout http-keep-alive 15s

frontend monitor-in
    bind 127.0.0.1:33305
    mode http
    option httplog
    monitor-uri /monitor

frontend k8s-master
    bind 127.0.0.1:8443
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    default_backend k8s-master

backend k8s-master
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
    server  ${node_hostname[0]}  ${node_ip[0]}:6443 check
    server  ${node_hostname[1]}  ${node_ip[1]}:6443 check
    server  ${node_hostname[2]}  ${node_ip[2]}:6443 check
EOF
    ${bin_path}/nerdctl run -d --name apiproxy --net host --restart always \
    -v ${cfg_path}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg haproxy
fi"

        for ((i = 0; i < num; i++)); do
            if remote_exec ${args[${i}]} "${command}"; then
                success "start apiproxy service on ${args[${i}]} successfully"
            fi
        done
    fi
}

function config_controller() {
    command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cfg_path}/pki/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${cfg_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config set-credentials kube-controller-manager \
  --client-certificate=${cfg_path}/pki/kube-controller-manager.pem \
  --client-key=${cfg_path}/pki/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=${cfg_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-controller-manager \
  --kubeconfig=${cfg_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${cfg_path}/kube-controller-manager.kubeconfig
cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-controller-manager \
--bind-address=0.0.0.0 \
--kubeconfig=${cfg_path}/kube-controller-manager.kubeconfig \
--allocate-node-cidrs=true \
--cluster-cidr=10.244.0.0/16 \
--service-cluster-ip-range=10.96.0.0/16 \
--cluster-signing-cert-file=${cfg_path}/pki/ca.pem \
--cluster-signing-key-file=${cfg_path}/pki/ca-key.pem \
--cluster-signing-duration=876000h0m0s \
--root-ca-file=${cfg_path}/pki/ca.pem \
--service-account-private-key-file=${cfg_path}/pki/sa.key \
--use-service-account-credentials=true \
--controllers=*,bootstrapsigner,tokencleaner \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target

EOF
systemctl daemon-reload
systemctl restart kube-controller-manager
systemctl enable kube-controller-manager"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "start kube-controller-manager service on ${i} successfully"
        fi
    done
}

function config_scheduler() {
    command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cfg_path}/pki/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${cfg_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config set-credentials kube-scheduler \
  --client-certificate=${cfg_path}/pki/kube-scheduler.pem \
  --client-key=${cfg_path}/pki/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=${cfg_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-scheduler \
  --kubeconfig=${cfg_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${cfg_path}/kube-scheduler.kubeconfig
cat > /usr/lib/systemd/system/kube-scheduler.service << EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-scheduler \
--bind-address=0.0.0.0 \
--kubeconfig=${cfg_path}/kube-scheduler.kubeconfig \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-scheduler
systemctl enable kube-scheduler"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "start kube-scheduler service on ${i} successfully"
        fi
    done
}

function config_kubectl() {
    if [ ! -f ${bin_path} ]; then mkdir -p ${bin_path}; fi

    if tar xf ${pkg_path}/${kubernetes_pkg} -C ${bin_path}; then
        success "deploy kubectl locally successfully"
    fi

    mkdir -p ${cfg_path}

    for i in "${master_node[@]}"; do
        command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cfg_path}/pki/ca.pem \
  --embed-certs=true \
  --server=https://${i}:6443 \
  --kubeconfig=${cfg_path}/admin.kubeconfig
${bin_path}/kubectl config set-credentials kubernetes-admin \
  --client-certificate=${cfg_path}/pki/admin.pem \
  --client-key=${cfg_path}/pki/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=${cfg_path}/admin.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kubernetes-admin \
  --kubeconfig=${cfg_path}/admin.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${cfg_path}/admin.kubeconfig
mkdir -p ~/.kube && \cp ${cfg_path}/admin.kubeconfig ~/.kube/config
${bin_path}/kubectl get cs"

        if remote_exec ${i} "${command}"; then
            success "set kubeconfig on ${i} successfully"
        fi
    done

    scp -P ${ssh_port} ${user}@${node_ip[0]}:${cfg_path}/admin.kubeconfig ${cfg_path}/admin.kubeconfig
    mkdir -p /root/.kube && \cp ${cfg_path}/admin.kubeconfig /root/.kube/config

    if ${bin_path}/kubectl get cs; then
        success "set kubeconfig on local machine successfully"
    fi
}

function config_kubelet() {
    args=($@)
    num=$#
    ((num /= 2))

    kubelet_bootstrap_kubeconfig=${run_path}/pki/kubelet-bootstrap.kubeconfig

    ${bin_path}/kubectl config set-cluster kubernetes \
        --certificate-authority=${run_path}/pki/ca.pem \
        --embed-certs=true \
        --server=${apiserver_url} \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${bin_path}/kubectl config set-credentials kubelet-bootstrap \
        --token=a5587b0a00bbbd5ead752f7074b4f644 \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${bin_path}/kubectl config set-context default \
        --cluster=kubernetes \
        --user=kubelet-bootstrap \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${bin_path}/kubectl config use-context default \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    echo 'apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubelet-bootstrap
' | ${bin_path}/kubectl apply -f -

    echo 'apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: \"true\"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - \"\"
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
      - pods/log
    verbs:
      - \"*\"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: \"\"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
' | ${bin_path}/kubectl apply -f -

    echo 'kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: auto-approve-csrs-for-group
subjects:
- kind: Group
  name: system:kubelet-bootstrap
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
  apiGroup: rbac.authorization.k8s.io
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: node-client-cert-renewal
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
  apiGroup: rbac.authorization.k8s.io
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: approve-node-server-renewal-csr
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/selfnodeserver"]
  verbs: ["create"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: node-server-cert-renewal
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: approve-node-server-renewal-csr
  apiGroup: rbac.authorization.k8s.io
' | ${bin_path}/kubectl apply -f -

    for ((i = 0; i < num; i++)); do
        if remote_cp "${kubelet_bootstrap_kubeconfig}" "${args[${i}]}:${cfg_path}/kubelet-bootstrap.kubeconfig"; then
            success "sync kubelet-bootstrap to ${args[${i}]} successfully"
        fi

        resolv_file=/run/systemd/resolve/resolv.conf
        result=$(remote_exec ${args[${i}]} "[ -f ${resolv_file} ] && echo '1' || echo '0'")
        if [ "$result" -eq 1 ]; then
            resolv_conf=/run/systemd/resolve/resolv.conf
        else
            resolv_conf=/etc/resolv.conf
        fi

        command="cat > ${cfg_path}/kubelet-config.yml << EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 10255
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: ${cfg_path}/pki/ca.pem 
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
resolvConf: ${resolv_conf}
containerLogMaxFiles: 10
containerLogMaxSize: 10Mi
evictionHard:
  imagefs.available: 15%
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
healthzBindAddress: 127.0.0.1
healthzPort: 10248
maxOpenFiles: 1000000
maxPods: 200
oomScoreAdj: -999
podPidsLimit: -1
EOF
cat > /usr/lib/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=${bin_path}/kubelet \
--kubeconfig=${cfg_path}/kubelet.kubeconfig \
--bootstrap-kubeconfig=${cfg_path}/kubelet-bootstrap.kubeconfig \
--config=${cfg_path}/kubelet-config.yml \
--container-runtime-endpoint=/run/containerd/containerd.sock \
--cert-dir=${cfg_path}/pki \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--node-labels=node.kubernetes.io/node=

Restart=always
StartLimitInterval=0
RestartSec=10
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kubelet
systemctl enable kubelet"

        if remote_exec ${args[${i}]} "${command}"; then
            success "start kubelet service on ${args[${i}]} successfully"
        fi
    done

    if [ "${args[*]}" == "${node_ip[*]}" ]; then
        until ${bin_path}/kubectl get csr | grep -c Approved,Issued | grep ${num}; do
            ${bin_path}/kubectl get csr
            sleep 2
        done

        until ${bin_path}/kubectl get node | grep -c -v '^NAME' | grep ${num}; do
            ${bin_path}/kubectl get node
            sleep 2
        done
    fi
}

function config_kubeproxy() {
    args=($@)
    num=$#

    ${bin_path}/kubectl config set-cluster kubernetes \
        --certificate-authority=${run_path}/pki/ca.pem \
        --embed-certs=true \
        --server=${apiserver_url} \
        --kubeconfig=${run_path}/pki/kube-proxy.kubeconfig

    ${bin_path}/kubectl config set-credentials kube-proxy \
        --client-certificate=${run_path}/pki/kube-proxy.pem \
        --client-key=${run_path}/pki/kube-proxy-key.pem \
        --embed-certs=true \
        --kubeconfig=${run_path}/pki/kube-proxy.kubeconfig

    ${bin_path}/kubectl config set-context default \
        --cluster=kubernetes \
        --user=kube-proxy \
        --kubeconfig=${run_path}/pki/kube-proxy.kubeconfig

    ${bin_path}/kubectl config use-context default \
        --kubeconfig=${run_path}/pki/kube-proxy.kubeconfig

    command="cat > ${cfg_path}/kube-proxy.yaml << EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: \"\"
  burst: 10
  contentType: application/vnd.kubernetes.protobuf
  kubeconfig: ${cfg_path}/kube-proxy.kubeconfig
  qps: 5
clusterCIDR: 10.244.0.0/16
configSyncPeriod: 15m0s
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: 1h0m0s
  tcpEstablishedTimeout: 24h0m0s
enableProfiling: false
healthzBindAddress: 0.0.0.0:10256
metricsBindAddress: 127.0.0.1:10249
iptables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncPeriod: 0s
  syncPeriod: 30s
ipvs:
  minSyncPeriod: 5s
  scheduler: \"rr\"
  syncPeriod: 30s
hostnameOverride: \"\"
mode: \"${kubeproxy_mode}\"
oomScoreAdj: -999
EOF
cat > /usr/lib/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-proxy \
--config=${cfg_path}/kube-proxy.yaml

Restart=on-failure
RestartSec=5
LimitNOFILE=655360

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-proxy
systemctl enable kube-proxy"

    for ((i = 0; i < num; i++)); do
        if remote_cp "${run_path}/pki/kube-proxy.kubeconfig" "${args[${i}]}:${cfg_path}/kube-proxy.kubeconfig"; then
            success "sync kube-proxy to ${args[${i}]} successfully"
        fi

        if remote_exec ${args[${i}]} "${command}"; then
            success "config kube-proxy service on ${args[${i}]} successfully"
        fi
    done
}

function config_registry() {
    if remote_exec ${node_ip[0]} "${bin_path}/nerdctl load -i /tmp/${registry_pkg}"; then
        success "load registry image on ${node_ip[0]} successfully"
    fi

    command="if ! ${bin_path}/nerdctl ps | grep registry; then
  ${bin_path}/nerdctl run -d --net=host --name registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/server-key.pem \
  -v ${cfg_path}/pki/registry.pem:/certs/server.pem \
  -v ${cfg_path}/pki/registry-key.pem:/certs/server-key.pem \
  -v ${base_path}/registry:/var/lib/registry \
  --restart=always registry
fi"

    if remote_exec ${node_ip[0]} "${command}"; then
        success "start registry service on ${node_ip[0]} successfully"
    fi
}

function install_flannel() {
    if [ ! -f ${pkg_path}/${flannel_pkg} ]; then
        download_pkg ${flannel_pkg}
    fi

    if sed -e "s#Placeholder_registry#${registry}#g" \
        -e "s#Placeholder_flannel_backend#${flannel_backend}#g" \
        ${pkg_path}/${flannel_pkg} | ${bin_path}/kubectl apply -f -; then
        success "install flannel successfully"
    fi

    until ${bin_path}/kubectl get node | grep -c Ready | grep ${#node_ip[@]}; do
        ${bin_path}/kubectl get node
        sleep 10
    done
    success "all k8s nodes are ready"
}

function install_coredns() {
    if [ ! -f ${pkg_path}/${coredns_pkg} ]; then
        download_pkg ${coredns_pkg}
    fi

    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/${coredns_pkg} | ${bin_path}/kubectl apply -f -; then
        success "install coredns successfully"
    fi
}

function install_metrics() {
    if [ ! -f ${pkg_path}/${metrics_pkg} ]; then
        download_pkg ${metrics_pkg}
    fi

    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/${metrics_pkg} | ${bin_path}/kubectl apply -f -; then
        success "install metrics-server successfully"
    fi
}

function install_localpath() {
    if [ ! -f ${pkg_path}/${localpath_pkg} ]; then
        download_pkg ${localpath_pkg}
    fi

    if sed -e "s#Placeholder_registry#${registry}#g" \
        -e "s#Placeholder_local_path#${local_path}#g" \
        ${pkg_path}/${localpath_pkg} | ${bin_path}/kubectl apply -f -; then
        success "install local-path-provisioner successfully"
    fi
}

function install_longhorn() {
    if [ ! -f ${pkg_path}/${longhorn_pkg} ]; then
        download_pkg ${longhorn_pkg}
    fi

    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/${longhorn_pkg} | ${bin_path}/kubectl apply -f -; then
        success "install longhorn successfully"
    fi
}

function install_cilium() {
    if [ ! -d ${pkg_path}/cilium ]; then tar -zxf ${pkg_path}/${cilium_pkg} -C ${pkg_path}; fi
    if [ ! -d ${bin_path} ]; then mkdir -p ${bin_path}; fi
    if [ ! -f ${bin_path}/cilium ]; then tar zxf ${pkg_path}/${cilium_cli_pkg} -C ${bin_path}; fi

    if [ "${cilium_mode}" == "native" ]; then
        if ${cilium_kubeProxyReplacement}; then
            ${bin_path}/cilium install --version ${cilium_version} \
                --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="10.244.0.0/16" \
                --set routingMode=native \
                --set autoDirectNodeRoutes=true \
                --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
                --set kubeProxyReplacement=true \
                --set k8sServiceHost=127.0.0.1 \
                --set k8sServicePort=8443 \
                --set loadBalancer.acceleration=best-effort \
                --set loadBalancer.mode=hybrid \
                --set bpf.masquerade=true \
                --set hubble.relay.enabled=true \
                --set hubble.ui.enabled=true \
                --set image.repository=${registry}/k8s/cilium \
                --set hubble.relay.image.repository=${registry}/k8s/hubble-relay \
                --set hubble.ui.backend.image.repository=${registry}/k8s/hubble-ui-backend \
                --set hubble.ui.frontend.image.repository=${registry}/k8s/hubble-ui \
                --set hubble.ui.backend.image.useDigest=false \
                --set hubble.ui.frontend.image.useDigest=false \
                --set envoy.image.repository=${registry}/k8s/cilium-envoy \
                --set envoy.image.useDigest=false \
                --set operator.image.repository=${registry}/k8s/operator \
                --chart-directory=${pkg_path}/cilium
        else
            ${bin_path}/cilium install --version ${cilium_version} \
                --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="10.244.0.0/16" \
                --set routingMode=native \
                --set autoDirectNodeRoutes=true \
                --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
                --set kubeProxyReplacement=false \
                --set nodePort.enabled=true \
                --set nodePort.enableHealthCheck=false \
                --set hostPort.enabled=true \
                --set externalIPs.enabled=true \
                --set loadBalancer.acceleration=best-effort \
                --set loadBalancer.mode=hybrid \
                --set bpf.masquerade=true \
                --set hubble.relay.enabled=true \
                --set hubble.ui.enabled=true \
                --set image.repository=${registry}/k8s/cilium \
                --set hubble.relay.image.repository=${registry}/k8s/hubble-relay \
                --set hubble.ui.backend.image.repository=${registry}/k8s/hubble-ui-backend \
                --set hubble.ui.frontend.image.repository=${registry}/k8s/hubble-ui \
                --set hubble.ui.backend.image.useDigest=false \
                --set hubble.ui.frontend.image.useDigest=false \
                --set envoy.image.repository=${registry}/k8s/cilium-envoy \
                --set envoy.image.useDigest=false \
                --set operator.image.repository=${registry}/k8s/operator \
                --chart-directory=${pkg_path}/cilium
        fi
    fi
    if [ "${cilium_mode}" == "tunnel" ]; then
        if ${cilium_kubeProxyReplacement}; then
            ${bin_path}/cilium install --version ${cilium_version} \
                --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="10.244.0.0/16" \
                --set routingMode=tunnel \
                --set tunnelProtocol=geneve \
                --set kubeProxyReplacement=true \
                --set k8sServiceHost=127.0.0.1 \
                --set k8sServicePort=8443 \
                --set bpf.masquerade=true \
                --set hubble.relay.enabled=true \
                --set hubble.ui.enabled=true \
                --set image.repository=${registry}/k8s/cilium \
                --set hubble.relay.image.repository=${registry}/k8s/hubble-relay \
                --set hubble.ui.backend.image.repository=${registry}/k8s/hubble-ui-backend \
                --set hubble.ui.frontend.image.repository=${registry}/k8s/hubble-ui \
                --set hubble.ui.backend.image.useDigest=false \
                --set hubble.ui.frontend.image.useDigest=false \
                --set envoy.image.repository=${registry}/k8s/cilium-envoy \
                --set envoy.image.useDigest=false \
                --set operator.image.repository=${registry}/k8s/operator \
                --chart-directory=${pkg_path}/cilium
        else
            ${bin_path}/cilium install --version ${cilium_version} \
                --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="10.244.0.0/16" \
                --set routingMode=tunnel \
                --set tunnelProtocol=geneve \
                --set kubeProxyReplacement=false \
                --set nodePort.enabled=true \
                --set nodePort.enableHealthCheck=false \
                --set hostPort.enabled=true \
                --set externalIPs.enabled=true \
                --set hubble.relay.enabled=true \
                --set hubble.ui.enabled=true \
                --set image.repository=${registry}/k8s/cilium \
                --set hubble.relay.image.repository=${registry}/k8s/hubble-relay \
                --set hubble.ui.backend.image.repository=${registry}/k8s/hubble-ui-backend \
                --set hubble.ui.frontend.image.repository=${registry}/k8s/hubble-ui \
                --set hubble.ui.backend.image.useDigest=false \
                --set hubble.ui.frontend.image.useDigest=false \
                --set envoy.image.repository=${registry}/k8s/cilium-envoy \
                --set envoy.image.useDigest=false \
                --set operator.image.repository=${registry}/k8s/operator \
                --chart-directory=${pkg_path}/cilium
        fi
    fi
}

function install_addons() {
    if [[ "${container_network}" == "flannel" ]]; then install_flannel; fi
    if [[ "${container_network}" == "cilium" ]]; then install_cilium; fi
    install_coredns
    install_metrics
    if [[ "${container_storage}" == "localpath" ]]; then install_localpath; fi
    if [[ "${container_storage}" == "longhorn" ]]; then install_longhorn; fi
}

if [ $# -eq 0 ]; then
    echo "Usage: ./k8s [command]
  Commands:
    install     Install the Kubernetes cluster.
    addnode     Adding nodes to the existing Kubernetes cluster.
    "
fi

if [ $# -eq 1 ]; then
    if [ $1 == "install" ]; then
        config_system "${node_ip_hostname[@]}"
        sync_pkg "${node_ip[@]}"
        config_etcd
        config_apiserver
        config_containerd "${node_ip[@]}"
        config_apiproxy "${node_ip[@]}"
        config_controller
        config_scheduler
        config_kubectl
        config_kubelet "${node_ip_hostname[@]}"
        if [[ "${container_network}" == "flannel" ]]; then
            config_kubeproxy "${node_ip[@]}"
        else
            if [[ "${cilium_kubeProxyReplacement}" == "false" ]]; then config_kubeproxy "${node_ip[@]}"; fi
        fi
        config_registry
        install_addons
    fi

    if [ $1 == "addnode" ]; then
        config_system "${addnode_ip_hostname[@]}"
        sync_hosts "${node_ip[@]}"
        sync_pkg "${addnode_ip[@]}"
        config_containerd "${addnode_ip[@]}"
        config_apiproxy "${addnode_ip[@]}"
        config_kubelet "${addnode_ip_hostname[@]}"
        config_kubeproxy "${addnode_ip[@]}"
    fi
fi
