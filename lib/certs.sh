# shellcheck shell=bash

# 将主机名/IP 列表渲染为 CSR JSON 的 "hosts" 数组(自动跳过空值, 避免空 SAN 条目)
function _json_hosts() {
    local first=1 h
    printf '"hosts": [\n'
    for h in "$@"; do
        [ -z "${h}" ] && continue
        if [ ${first} -eq 1 ]; then
            first=0
        else
            printf ',\n'
        fi
        printf '    "%s"' "${h}"
    done
    printf '\n  ]'
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
    # 幂等保护: 证书已存在则跳过生成, 避免重跑 install 时重新签发 CA 导致集群组件证书失配
    if [ -f ca.pem ] && [ -f etcd-ca.pem ] && [ -f kube-apiserver.pem ] && [ -f etcd.pem ] && [ -f sa.key ]; then
        note "certificates already exist, skip generation"
        cd ${run_path} || exit
        return 0
    fi
    if ${pkg_path}/bin/cfssl gencert -initca ca-csr.json | ${pkg_path}/bin/cfssljson -bare ca; then
        success "k8s ca certificate created"
    fi
    if ${pkg_path}/bin/cfssl gencert -initca etcd-ca-csr.json | ${pkg_path}/bin/cfssljson -bare etcd-ca; then
        success "etcd ca certificate created"
    fi

    # 各证书 SAN 列表统一从实际 master 数量派生, HA/非HA共用一套模板
    local etcd_hosts_json apiserver_hosts_json registry_hosts_json service_api_ip svc_base
    local -a etcd_hosts apiserver_hosts registry_hosts master_hostnames
    local j
    for ((j = 0; j < ${#master_node[@]}; j++)); do
        etcd_hosts+=("${node_ip[${j}]}")
        apiserver_hosts+=("${node_ip[${j}]}")
        registry_hosts+=("${node_ip[${j}]}")
        master_hostnames+=("${node_hostname[${j}]}")
    done

    # service_cidr 网段首个地址作为 apiserver Service ClusterIP(如 10.96.0.0/16 -> 10.96.0.1)
    svc_base=${service_cidr%%/*}
    service_api_ip=${svc_base%.*}.1

    etcd_hosts_json=$(_json_hosts "localhost" "127.0.0.1" "${etcd_hosts[@]}")
    apiserver_hosts_json=$(_json_hosts "localhost" "127.0.0.1" "${apiserver_hosts[@]}" \
        "${master_hostnames[@]}" "${service_api_ip}" "kubernetes" "kubernetes.default" \
        "kubernetes.default.svc" "kubernetes.default.svc.${cluster_domain%%.*}" \
        "kubernetes.default.svc.${cluster_domain}")
    registry_hosts_json=$(_json_hosts "${registry_hosts[@]}")

    cat >etcd-csr.json <<EOF
{
  "CN": "etcd",
  ${etcd_hosts_json},
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

    if ${pkg_path}/bin/cfssl gencert -ca=etcd-ca.pem -ca-key=etcd-ca-key.pem -config=ca-config.json \
        -profile=kubernetes etcd-csr.json | ${pkg_path}/bin/cfssljson -bare etcd; then
        success "etcd server certificate created"
    fi

    cat >kube-apiserver-csr.json <<EOF
{
  "CN": "kubernetes",
  ${apiserver_hosts_json},
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
  ${registry_hosts_json},
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
    # master 需要控制面/etcd/签名所需的完整证书与私钥
    local master_certs=(
        ca.pem ca-key.pem
        etcd-ca.pem etcd-ca-key.pem etcd.pem etcd-key.pem
        kube-apiserver.pem kube-apiserver-key.pem
        kube-controller-manager.pem kube-controller-manager-key.pem
        kube-scheduler.pem kube-scheduler-key.pem
        admin.pem admin-key.pem
        kube-proxy.pem kube-proxy-key.pem
        sa.key sa.pub
        registry.pem registry-key.pem
    )
    # worker 仅信任集群 CA: kubelet/kube-proxy 身份凭证通过各自 kubeconfig 单独分发
    local worker_certs=(ca.pem)
    # 历史版本曾把整套 pki 推给所有节点, worker 接入时先清除残留私钥与多余证书
    local worker_cleanup="cd ${cert_path} 2>/dev/null && rm -f \
ca-key.pem etcd-ca.pem etcd-ca-key.pem etcd.pem etcd-key.pem \
kube-apiserver.pem kube-apiserver-key.pem \
kube-controller-manager.pem kube-controller-manager-key.pem \
kube-scheduler.pem kube-scheduler-key.pem \
admin.pem admin-key.pem kube-proxy.pem kube-proxy-key.pem \
proxy-client.pem proxy-client-key.pem sa.key sa.pub \
registry.pem registry-key.pem || true"

    # Update ca-trust: 仅信任实际存在的 CA 文件(worker 没有 etcd-ca.pem)
    local command_trust="if [ -d /etc/pki/ca-trust ]; then
    update-ca-trust force-enable 2>/dev/null || true
    [ -f ${cert_path}/ca.pem ] && \\cp -f ${cert_path}/ca.pem /etc/pki/ca-trust/source/anchors/k8s-ca.pem
    [ -f ${cert_path}/etcd-ca.pem ] && \\cp -f ${cert_path}/etcd-ca.pem /etc/pki/ca-trust/source/anchors/etcd-ca.pem
    update-ca-trust extract
fi
if [ -d /usr/local/share/ca-certificates ]; then
    [ -f ${cert_path}/ca.pem ] && \\cp -f ${cert_path}/ca.pem /usr/local/share/ca-certificates/k8s.crt
    [ -f ${cert_path}/etcd-ca.pem ] && \\cp -f ${cert_path}/etcd-ca.pem /usr/local/share/ca-certificates/etcd.crt
    update-ca-certificates
fi"

    local host is_master m
    for host in "$@"; do
        is_master=0
        for m in "${master_node[@]}"; do
            [ "${host}" == "${m}" ] && is_master=1
        done

        remote_exec "${host}" "mkdir -p ${cert_path}"

        if [ ${is_master} -eq 1 ]; then
            remote_send_files "${host}" "${pki_path}" "${cert_path}" "${master_certs[@]}"
            success "${host} control-plane certs synced"
        else
            remote_exec "${host}" "${worker_cleanup}"
            remote_send_files "${host}" "${pki_path}" "${cert_path}" "${worker_certs[@]}"
            success "${host} worker certs synced (CA only)"
        fi

        if remote_exec "${host}" "${command_trust}"; then
            success "${host} update-ca-trust"
        fi
    done
}
