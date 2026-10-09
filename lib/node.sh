# shellcheck shell=bash

function config_containerd() {
    args=($@)
    num=$#

    # 每次部署使用独立临时目录, 避免并发部署冲突或分发到上次运行的残留文件
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/k8s-containerd.XXXXXX)

    command1="/usr/local/bin/containerd config default > /tmp/config.toml"
    # 生成或拉取失败都会立即中止(remote_* 内部 error 退出), 不会带着陈旧文件继续分发
    remote_exec ${args[0]} "${command1}"
    remote_pull "${args[0]}" "/tmp/config.toml" "${tmp_dir}/config.toml"
    sed -i -e "s#registry.k8s.io/pause#${registry}/k8s/pause#g" \
        -e "s#level = ''#level = 'error'#g" \
        -e "s#device_ownership_from_security_context = false#device_ownership_from_security_context = true#g" \
        "${tmp_dir}/config.toml"
    echo -e "server = \"https://${registry}\"\n\n[host.\"https://${registry}\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  ca = \"${cert_path}/ca.pem\"" >"${tmp_dir}/hosts.toml"

    command2="sed -i '/^LimitCORE=infinity$/aLimitNOFILE=655360' /usr/local/lib/systemd/system/containerd.service
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd"

    command3="mkdir -p /opt/cni/bin && cp -r /usr/local/libexec/cni/* /opt/cni/bin/"

    for ((i = 0; i < num; i++)); do
        if
            remote_exec ${args[${i}]} "mkdir -p /etc/containerd/certs.d/${registry}" &&
                remote_cp "${tmp_dir}/config.toml" ${args[${i}]}:/etc/containerd/config.toml &&
                remote_cp "${tmp_dir}/hosts.toml" ${args[${i}]}:/etc/containerd/certs.d/${registry}/hosts.toml
        then
            if remote_exec ${args[${i}]} "${command2}"; then
                success "${args[${i}]} containerd service started"
            fi

            if remote_exec ${args[${i}]} "${command3}"; then
                success "${args[${i}]} cni bin copied"
            fi
        fi
    done

    rm -rf "${tmp_dir}"
}

function config_apiproxy() {
    args=($@)
    num=$#

    if [ ${#master_node[@]} -eq 3 ]; then
        command="if ! /usr/local/bin/nerdctl ps |grep apiproxy; then
    /usr/local/bin/nerdctl load -i /tmp/${haproxy_file}
    cat > ${conf_path}/haproxy.cfg <<EOF
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
    /usr/local/bin/nerdctl run -d --name apiproxy --net host --restart always \
    -v ${conf_path}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg haproxy:${haproxy_version}
fi"

        for ((i = 0; i < num; i++)); do
            if remote_exec ${args[${i}]} "${command}"; then
                success "${args[${i}]} apiproxy service started"
            fi
        done
    fi
}

function config_kubelet() {
    args=($@)
    num=$#
    ((num /= 2))

    kubelet_bootstrap_kubeconfig=${pki_path}/kubelet-bootstrap.kubeconfig

    ${pkg_path}/bin/kubectl config set-cluster kubernetes \
        --certificate-authority=${pki_path}/ca.pem \
        --embed-certs=true \
        --server=${apiserver_url} \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${pkg_path}/bin/kubectl config set-credentials kubelet-bootstrap \
        --token=${kube_token} \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${pkg_path}/bin/kubectl config set-context default \
        --cluster=kubernetes \
        --user=kubelet-bootstrap \
        --kubeconfig=${kubelet_bootstrap_kubeconfig}

    ${pkg_path}/bin/kubectl config use-context default \
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
---
apiVersion: rbac.authorization.k8s.io/v1
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
---
kind: ClusterRoleBinding
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
' | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -

    # 重跑 install 时校验节点上 kubelet 自动生成的 kubelet.kubeconfig 是否仍使用当前 CA;
    # CA 失配(如曾重新签发)时 kubelet 无法通过 apiserver 认证, 删除后 kubelet 会通过
    # bootstrap-kubeconfig 重新签发。
    local_ca_sha=$(sha256sum ${pki_path}/ca.pem 2>/dev/null | awk '{print $1}')

    for ((i = 0; i < num; i++)); do
        if remote_cp "${kubelet_bootstrap_kubeconfig}" "${args[${i}]}:${conf_path}/kubelet-bootstrap.kubeconfig"; then
            success "${args[${i}]} kubelet-bootstrap synced"
        fi

        resolv_file=/run/systemd/resolve/resolv.conf
        result=$(remote_capture ${args[${i}]} "[ -f ${resolv_file} ] && echo '1' || echo '0'" | tail -n 1) || result=
        if [ "$result" == "1" ]; then
            resolv_conf=${resolv_file}
        else
            resolv_conf=/etc/resolv.conf
        fi

        command="cat > ${conf_path}/kubelet-config.yml << EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: ${cert_path}/ca.pem 
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
cgroupDriver: systemd
cgroupsPerQOS: true
clusterDNS:
- ${cluster_dns}
clusterDomain: ${cluster_domain}
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
cat > ${systemd_path}/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=${bin_path}/kubelet \
--kubeconfig=${conf_path}/kubelet.kubeconfig \
--bootstrap-kubeconfig=${conf_path}/kubelet-bootstrap.kubeconfig \
--config=${conf_path}/kubelet-config.yml \
--container-runtime-endpoint=/run/containerd/containerd.sock \
--cert-dir=${cert_path} \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--node-labels=node.kubernetes.io/node=

Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
# 校验 kubelet.kubeconfig 内嵌 CA 是否与当前 CA 一致, 失配则删除以强制重新签发
if [ -f ${conf_path}/kubelet.kubeconfig ] && [ -n "${local_ca_sha}" ]; then
    node_ca_sha=\$(awk '/certificate-authority-data:/{print \$2}' ${conf_path}/kubelet.kubeconfig | base64 -d 2>/dev/null | sha256sum | awk '{print \$1}')
    if [ "\$node_ca_sha" != "${local_ca_sha}" ]; then
        echo 'kubelet.kubeconfig CA mismatch, removing to force re-bootstrap'
        rm -f ${conf_path}/kubelet.kubeconfig
    fi
fi
systemctl daemon-reload
systemctl enable kubelet
systemctl restart kubelet"

        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} kubelet service started"
        fi
    done

    # 仅安装全部节点时等待 CSR 签发与 Node 注册(addnode 场景不在此函数判断)
    # 每步最长等待 5 分钟(150 x 2s), 超时输出现场后中止, 不再无限挂起
    if [ "${args[*]}" == "${node_ip_hostname[*]}" ]; then
        wait_until "${num} CSRs approved/issued" 150 2 bash -c "
            [ \"\$(${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get csr | grep -c Approved,Issued)\" -ge '${num}' ]
        " || { ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get csr; error "CSR approval timeout"; }

        wait_until "${num} nodes registered" 150 2 bash -c "
            [ \"\$(${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node --no-headers | grep -c .)\" -ge '${num}' ]
        " || { ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node; error "node registration timeout"; }
    fi
}

function config_kubeproxy() {
    args=($@)
    num=$#

    kube_proxy_kubeconfig=${pki_path}/kube-proxy.kubeconfig

    ${pkg_path}/bin/kubectl config set-cluster kubernetes \
        --certificate-authority=${pki_path}/ca.pem \
        --embed-certs=true \
        --server=${apiserver_url} \
        --kubeconfig=${kube_proxy_kubeconfig}

    ${pkg_path}/bin/kubectl config set-credentials kube-proxy \
        --client-certificate=${pki_path}/kube-proxy.pem \
        --client-key=${pki_path}/kube-proxy-key.pem \
        --embed-certs=true \
        --kubeconfig=${kube_proxy_kubeconfig}

    ${pkg_path}/bin/kubectl config set-context default \
        --cluster=kubernetes \
        --user=kube-proxy \
        --kubeconfig=${kube_proxy_kubeconfig}

    ${pkg_path}/bin/kubectl config use-context default \
        --kubeconfig=${kube_proxy_kubeconfig}

    command="cat > ${conf_path}/kube-proxy.yaml << EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: \"\"
  burst: 10
  contentType: application/vnd.kubernetes.protobuf
  kubeconfig: ${conf_path}/kube-proxy.kubeconfig
  qps: 5
clusterCIDR: ${cluster_cidr}
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
cat > ${systemd_path}/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-proxy \
--config=${conf_path}/kube-proxy.yaml

Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kube-proxy
systemctl restart kube-proxy"

    for ((i = 0; i < num; i++)); do
        if remote_cp "${kube_proxy_kubeconfig}" "${args[${i}]}:${conf_path}/kube-proxy.kubeconfig"; then
            success "${args[${i}]} kube-proxy synced"
        fi

        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} kube-proxy service started"
        fi
    done
}

function config_registry() {
    if remote_exec ${node_ip[0]} "/usr/local/bin/nerdctl load -i /tmp/${registry_file}"; then
        success "${node_ip[0]} registry image loaded"
    fi

    command="if ! /usr/local/bin/nerdctl ps | grep registry; then
  /usr/local/bin/nerdctl run -d --net=host --name registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/server-key.pem \
  -v ${cert_path}/registry.pem:/certs/server.pem \
  -v ${cert_path}/registry-key.pem:/certs/server-key.pem \
  -v ${registry_data_path}:/var/lib/registry \
  --restart always registry:${registry_version}
fi"

    if remote_exec ${node_ip[0]} "${command}"; then
        success "${node_ip[0]} registry service started"
    fi
}

