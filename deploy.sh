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
ExecStart=${install_path}/bin/etcd --name=${node_hostname[${nm}]} \
--data-dir=${data_path}/etcd \
--wal-dir=${data_path}/etcd/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380,${node_hostname[1]}=https://${node_ip[1]}:2380,${node_hostname[2]}=https://${node_ip[2]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${install_path}/etc/pki/etcd.pem \
--key-file=${install_path}/etc/pki/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${install_path}/etc/pki/etcd-ca.pem \
--peer-cert-file=${install_path}/etc/pki/etcd.pem \
--peer-key-file=${install_path}/etc/pki/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${install_path}/etc/pki/etcd-ca.pem \
--auto-compaction-mode=periodic \
--auto-compaction-retention=1 \
--max-request-bytes=33554432 \
--quota-backend-bytes=6442450944 \
--heartbeat-interval=250 \
--election-timeout=2000 \
--cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
RestartSec=10
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
Alias=etcd3.service

EOF
systemctl daemon-reload
systemctl restart etcd
systemctl enable etcd"

            if remote_exec ${i} "${command}"; then
                success "${i} etcd service started"
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
ExecStart=${install_path}/bin/etcd --name=${node_hostname[${nm}]} \
--data-dir=${data_path}/etcd \
--wal-dir=${data_path}/etcd/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${install_path}/etc/pki/etcd.pem \
--key-file=${install_path}/etc/pki/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${install_path}/etc/pki/etcd-ca.pem \
--peer-cert-file=${install_path}/etc/pki/etcd.pem \
--peer-key-file=${install_path}/etc/pki/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${install_path}/etc/pki/etcd-ca.pem \
--auto-compaction-mode=periodic \
--auto-compaction-retention=1 \
--max-request-bytes=33554432 \
--quota-backend-bytes=6442450944 \
--heartbeat-interval=250 \
--election-timeout=2000 \
--cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
RestartSec=10
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
Alias=etcd3.service

EOF
systemctl daemon-reload
systemctl restart etcd
systemctl enable etcd"

            if remote_exec ${i} "${command}"; then
                success "${i} etcd service started"
            fi
        done
    fi

    if [ ${#master_node[@]} -eq 3 ]; then
        command="ETCDCTL_API=3 ${install_path}/bin/etcdctl \
--cacert=${install_path}/etc/pki/etcd-ca.pem \
--cert=${install_path}/etc/pki/etcd.pem \
--key=${install_path}/etc/pki/etcd-key.pem \
--endpoints="https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379" \
endpoint status --write-out=table"

        if remote_exec ${node_ip[0]} "${command}"; then
            success "etcd cluster started"
        fi
    else
        command="ETCDCTL_API=3 ${install_path}/bin/etcdctl \
--cacert=${install_path}/etc/pki/etcd-ca.pem \
--cert=${install_path}/etc/pki/etcd.pem \
--key=${install_path}/etc/pki/etcd-key.pem \
--endpoints="https://${node_ip[0]}:2379" \
endpoint status --write-out=table"

        if remote_exec ${node_ip[0]} "${command}"; then
            success "etcd cluster started"
        fi
    fi
}

function config_apiserver() {
    if [ ${#master_node[@]} -eq 3 ]; then
        for i in "${master_node[@]}"; do
            command="cat > ${install_path}/etc/token.csv <<EOF
${kube_token},kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${install_path}/bin/kube-apiserver \
--apiserver-count=3 \
--etcd-servers=https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379 \
--etcd-cafile=${install_path}/etc/pki/etcd-ca.pem \
--etcd-certfile=${install_path}/etc/pki/etcd.pem \
--etcd-keyfile=${install_path}/etc/pki/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction,DefaultTolerationSeconds,DefaultStorageClass \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${install_path}/etc/token.csv \
--kubelet-client-certificate=${install_path}/etc/pki/kube-apiserver.pem \
--kubelet-client-key=${install_path}/etc/pki/kube-apiserver-key.pem \
--tls-cert-file=${install_path}/etc/pki/kube-apiserver.pem  \
--tls-private-key-file=${install_path}/etc/pki/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${install_path}/etc/pki/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${install_path}/etc/pki/sa.key \
--service-account-key-file=${install_path}/etc/pki/sa.pub \
--proxy-client-cert-file=${install_path}/etc/pki/kube-apiserver.pem \
--proxy-client-key-file=${install_path}/etc/pki/kube-apiserver-key.pem \
--requestheader-client-ca-file=${install_path}/etc/pki/ca.pem \
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
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-apiserver
systemctl enable kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "${i} kube-apiserver service started"
            fi
        done
    else
        for i in "${master_node[@]}"; do
            command="cat > ${install_path}/etc/token.csv <<EOF
${kube_token},kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${install_path}/bin/kube-apiserver \
--apiserver-count=1 \
--etcd-servers=https://${node_ip[0]}:2379 \
--etcd-cafile=${install_path}/etc/pki/etcd-ca.pem \
--etcd-certfile=${install_path}/etc/pki/etcd.pem \
--etcd-keyfile=${install_path}/etc/pki/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${install_path}/etc/token.csv \
--kubelet-client-certificate=${install_path}/etc/pki/kube-apiserver.pem \
--kubelet-client-key=${install_path}/etc/pki/kube-apiserver-key.pem \
--tls-cert-file=${install_path}/etc/pki/kube-apiserver.pem  \
--tls-private-key-file=${install_path}/etc/pki/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${install_path}/etc/pki/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${install_path}/etc/pki/sa.key \
--service-account-key-file=${install_path}/etc/pki/sa.pub \
--proxy-client-cert-file=${install_path}/etc/pki/kube-apiserver.pem \
--proxy-client-key-file=${install_path}/etc/pki/kube-apiserver-key.pem \
--requestheader-client-ca-file=${install_path}/etc/pki/ca.pem \
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
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-apiserver
systemctl enable kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "${i} kube-apiserver service started"
            fi
        done
    fi
}

function config_containerd() {
    args=($@)
    num=$#

    command1="/usr/local/bin/containerd config default > /tmp/config.toml"

    if remote_exec ${args[0]} "${command1}"; then
        if scp -i ${ssh_key} -P ${ssh_port} ${ssh_user}@${args[0]}:/tmp/config.toml /tmp/config.toml; then
            sed -i -e "s#registry.k8s.io/pause#${registry}/k8s/pause#g" \
                -e "s#level = ''#level = 'error'#g" \
                -e "s#device_ownership_from_security_context = false#device_ownership_from_security_context = true#g" \
                /tmp/config.toml
            echo -e "server = \"https://${registry}\"\n\n[host.\"https://${registry}\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  ca = \"${install_path}/etc/pki/ca.pem\"" >/tmp/hosts.toml
        fi
    fi

    command2="sed -i '/^LimitCORE=infinity$/aLimitNOFILE=655360' /usr/local/lib/systemd/system/containerd.service
systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd"

    command3="mkdir -p /opt/cni/bin && cp -r /usr/local/libexec/cni/* /opt/cni/bin/"

    for ((i = 0; i < num; i++)); do
        if
            remote_exec ${args[${i}]} "mkdir -p /etc/containerd/certs.d/${registry}" &&
                remote_cp /tmp/config.toml ${args[${i}]}:/etc/containerd/config.toml &&
                remote_cp /tmp/hosts.toml ${args[${i}]}:/etc/containerd/certs.d/${registry}/hosts.toml
        then
            if remote_exec ${args[${i}]} "${command2}"; then
                success "${args[${i}]} containerd service started"
            fi

            if remote_exec ${args[${i}]} "${command3}"; then
                success "${args[${i}]} cni bin copied"
            fi
        fi
    done
}

function config_apiproxy() {
    args=($@)
    num=$#

    if [ ${#master_node[@]} -eq 3 ]; then
        command="if ! /usr/local/bin/nerdctl ps |grep apiproxy; then
    /usr/local/bin/nerdctl load -i /tmp/${haproxy_file}
    cat > ${install_path}/etc/haproxy.cfg <<EOF
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
    -v ${install_path}/etc/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg haproxy:${haproxy_version}
fi"

        for ((i = 0; i < num; i++)); do
            if remote_exec ${args[${i}]} "${command}"; then
                success "${args[${i}]} apiproxy service started"
            fi
        done
    fi
}

function config_controller() {
    command="${install_path}/bin/kubectl config set-cluster kubernetes \
  --certificate-authority=${install_path}/etc/pki/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${install_path}/etc/kube-controller-manager.kubeconfig
${install_path}/bin/kubectl config set-credentials kube-controller-manager \
  --client-certificate=${install_path}/etc/pki/kube-controller-manager.pem \
  --client-key=${install_path}/etc/pki/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=${install_path}/etc/kube-controller-manager.kubeconfig
${install_path}/bin/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-controller-manager \
  --kubeconfig=${install_path}/etc/kube-controller-manager.kubeconfig
${install_path}/bin/kubectl config use-context default \
  --kubeconfig=${install_path}/etc/kube-controller-manager.kubeconfig
cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${install_path}/bin/kube-controller-manager \
--bind-address=0.0.0.0 \
--kubeconfig=${install_path}/etc/kube-controller-manager.kubeconfig \
--allocate-node-cidrs=true \
--cluster-cidr=10.244.0.0/16 \
--service-cluster-ip-range=10.96.0.0/16 \
--cluster-signing-cert-file=${install_path}/etc/pki/ca.pem \
--cluster-signing-key-file=${install_path}/etc/pki/ca-key.pem \
--cluster-signing-duration=876000h0m0s \
--root-ca-file=${install_path}/etc/pki/ca.pem \
--service-account-private-key-file=${install_path}/etc/pki/sa.key \
--use-service-account-credentials=true \
--controllers=*,bootstrapsigner,tokencleaner \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

EOF
systemctl daemon-reload
systemctl restart kube-controller-manager
systemctl enable kube-controller-manager"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "${i} kube-controller-manager service started"
        fi
    done
}

function config_scheduler() {
    command="${install_path}/bin/kubectl config set-cluster kubernetes \
  --certificate-authority=${install_path}/etc/pki/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${install_path}/etc/kube-scheduler.kubeconfig
${install_path}/bin/kubectl config set-credentials kube-scheduler \
  --client-certificate=${install_path}/etc/pki/kube-scheduler.pem \
  --client-key=${install_path}/etc/pki/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=${install_path}/etc/kube-scheduler.kubeconfig
${install_path}/bin/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-scheduler \
  --kubeconfig=${install_path}/etc/kube-scheduler.kubeconfig
${install_path}/bin/kubectl config use-context default \
  --kubeconfig=${install_path}/etc/kube-scheduler.kubeconfig
cat > /usr/lib/systemd/system/kube-scheduler.service << EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${install_path}/bin/kube-scheduler \
--bind-address=0.0.0.0 \
--kubeconfig=${install_path}/etc/kube-scheduler.kubeconfig \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384

Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-scheduler
systemctl enable kube-scheduler"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "${i} kube-scheduler service started"
        fi
    done
}

function config_kubeconfig() {
    for i in "${master_node[@]}"; do
        command="${install_path}/bin/kubectl config set-cluster kubernetes \
  --certificate-authority=${install_path}/etc/pki/ca.pem \
  --embed-certs=true \
  --server=https://${i}:6443 \
  --kubeconfig=${install_path}/etc/admin.kubeconfig
${install_path}/bin/kubectl config set-credentials kubernetes-admin \
  --client-certificate=${install_path}/etc/pki/admin.pem \
  --client-key=${install_path}/etc/pki/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=${install_path}/etc/admin.kubeconfig
${install_path}/bin/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kubernetes-admin \
  --kubeconfig=${install_path}/etc/admin.kubeconfig
${install_path}/bin/kubectl config use-context default \
  --kubeconfig=${install_path}/etc/admin.kubeconfig
mkdir -p ~/.kube && \cp ${install_path}/etc/admin.kubeconfig ~/.kube/config
${install_path}/bin/kubectl get cs"
        if remote_exec ${i} "${command}"; then
            success "${i} kubeconfig setted"
        fi
    done

    scp -i ${ssh_key} -P ${ssh_port} ${ssh_user}@${node_ip[0]}:${install_path}/etc/admin.kubeconfig ${run_path}/admin.kubeconfig

    if ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get cs; then
        success "local kubeconfig setted"
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

    for ((i = 0; i < num; i++)); do
        if remote_cp "${kubelet_bootstrap_kubeconfig}" "${args[${i}]}:${install_path}/etc/kubelet-bootstrap.kubeconfig"; then
            success "${args[${i}]} kubelet-bootstrap synced"
        fi

        resolv_file=/run/systemd/resolve/resolv.conf
        result=$(remote_exec ${args[${i}]} "[ -f ${resolv_file} ] && echo '1' || echo '0'")
        if [ "$result" -eq 1 ]; then
            resolv_conf=/run/systemd/resolve/resolv.conf
        else
            resolv_conf=/etc/resolv.conf
        fi

        command="cat > ${install_path}/etc/kubelet-config.yml << EOF
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
    clientCAFile: ${install_path}/etc/pki/ca.pem 
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
ExecStart=${install_path}/bin/kubelet \
--kubeconfig=${install_path}/etc/kubelet.kubeconfig \
--bootstrap-kubeconfig=${install_path}/etc/kubelet-bootstrap.kubeconfig \
--config=${install_path}/etc/kubelet-config.yml \
--container-runtime-endpoint=/run/containerd/containerd.sock \
--cert-dir=${install_path}/etc/pki \
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
systemctl daemon-reload
systemctl restart kubelet
systemctl enable kubelet"

        if remote_exec ${args[${i}]} "${command}"; then
            success "${args[${i}]} kubelet service started"
        fi
    done

    if [ "${args[*]}" == "${node_ip[*]}" ]; then
        until ${pkg_path}/bin/kubectl get --kubeconfig ${run_path}/admin.kubeconfig csr | grep -c Approved,Issued | grep ${num}; do
            ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get csr
            sleep 2
        done

        until ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node | grep -c -v '^NAME' | grep ${num}; do
            ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node
            sleep 2
        done
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

    command="cat > ${install_path}/etc/kube-proxy.yaml << EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: \"\"
  burst: 10
  contentType: application/vnd.kubernetes.protobuf
  kubeconfig: ${install_path}/etc/kube-proxy.kubeconfig
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
ExecStart=${install_path}/bin/kube-proxy \
--config=${install_path}/etc/kube-proxy.yaml

Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNPROC=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart kube-proxy
systemctl enable kube-proxy"

    for ((i = 0; i < num; i++)); do
        if remote_cp "${kube_proxy_kubeconfig}" "${args[${i}]}:${install_path}/etc/kube-proxy.kubeconfig"; then
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
  -v ${install_path}/etc/pki/registry.pem:/certs/server.pem \
  -v ${install_path}/etc/pki/registry-key.pem:/certs/server-key.pem \
  -v ${data_path}/registry:/var/lib/registry \
  --Restart=on-failure registry:${registry_version}
fi"

    if remote_exec ${node_ip[0]} "${command}"; then
        success "${node_ip[0]} registry service started"
    fi
}

function install_cni_plugin() {
    if [ "${cni_plugin}" == "flannel" ]; then
        if sed -e "s#Placeholder_registry#${registry}#g" \
            ${pkg_path}/yaml/${flannel_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
            success "flannel installed"
        fi
    fi

    if [ "${cni_plugin}" == "calico" ]; then
        if sed -e "s#Placeholder_registry#${registry}#g" \
            ${pkg_path}/yaml/${calico_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
            success "calico installed"
        fi
    fi

    until ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node | grep -c Ready | grep ${#node_ip[@]}; do
        ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get node
        sleep 10
    done
    success "all k8s nodes are ready"
}

function install_coredns() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${coredns_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "coredns installed"
    fi
}

function install_metrics() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        ${pkg_path}/yaml/${metrics_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "metrics-server installed"
    fi
}

function install_localpath() {
    if sed -e "s#Placeholder_registry#${registry}#g" \
        -e "s#Placeholder_local_path#${data_path}#g" \
        ${pkg_path}/yaml/${localpath_file} | ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig apply -f -; then
        success "local-path-provisioner installed"
    fi
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
        check_pkg
        config_certs
        config_system "${node_ip_hostname[@]}"
        sync_hosts "${node_ip[@]}"
        sync_certs "${node_ip[@]}"
        sync_pkg "${node_ip[@]}"
        config_etcd
        config_apiserver
        config_containerd "${node_ip[@]}"
        config_apiproxy "${node_ip[@]}"
        config_controller
        config_scheduler
        config_kubeconfig
        config_kubelet "${node_ip_hostname[@]}"
        config_kubeproxy "${node_ip[@]}"
        config_registry
        install_cni_plugin
        install_coredns
        install_metrics
        install_localpath
    fi

    if [ $1 == "addnode" ]; then
        check_pkg
        config_system "${addnode_ip_hostname[@]}"
        sync_hosts "${node_ip[@]}"
        sync_certs "${addnode_ip[@]}"
        sync_pkg "${addnode_ip[@]}"
        config_containerd "${addnode_ip[@]}"
        config_apiproxy "${addnode_ip[@]}"
        config_kubelet "${addnode_ip_hostname[@]}"
        config_kubeproxy "${addnode_ip[@]}"
    fi
fi

