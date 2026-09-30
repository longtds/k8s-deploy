# shellcheck shell=bash

function config_etcd() {
    nm=0

    if [ ${#master_node[@]} -eq 3 ]; then
        for i in "${master_node[@]}"; do
            command="cat > ${systemd_path}/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target

[Service]
Type=notify
ExecStart=${bin_path}/etcd --name=${node_hostname[${nm}]} \
--data-dir=${etcd_data_path} \
--wal-dir=${etcd_data_path}/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380,${node_hostname[1]}=https://${node_ip[1]}:2380,${node_hostname[2]}=https://${node_ip[2]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${cert_path}/etcd.pem \
--key-file=${cert_path}/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${cert_path}/etcd-ca.pem \
--peer-cert-file=${cert_path}/etcd.pem \
--peer-key-file=${cert_path}/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${cert_path}/etcd-ca.pem \
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
systemctl enable etcd
systemctl --no-block restart etcd"

            if remote_exec ${i} "${command}"; then
                success "${i} etcd service started"
            fi
            ((nm = nm + 1))
        done
    else
        for i in "${master_node[@]}"; do
            command="cat > ${systemd_path}/etcd.service <<EOF
[Unit]
Description=Etcd Server
After=network.target

[Service]
Type=notify
ExecStart=${bin_path}/etcd --name=${node_hostname[${nm}]} \
--data-dir=${etcd_data_path} \
--wal-dir=${etcd_data_path}/wal \
--listen-peer-urls=https://${i}:2380 \
--listen-client-urls=https://${i}:2379,http://127.0.0.1:2379 \
--initial-advertise-peer-urls=https://${i}:2380 \
--advertise-client-urls=https://${i}:2379 \
--initial-cluster=${node_hostname[0]}=https://${node_ip[0]}:2380 \
--initial-cluster-token=etcd-k8s-cluster \
--initial-cluster-state=new \
--cert-file=${cert_path}/etcd.pem \
--key-file=${cert_path}/etcd-key.pem \
--client-cert-auth=true \
--trusted-ca-file=${cert_path}/etcd-ca.pem \
--peer-cert-file=${cert_path}/etcd.pem \
--peer-key-file=${cert_path}/etcd-key.pem \
--peer-client-cert-auth=true \
--peer-trusted-ca-file=${cert_path}/etcd-ca.pem \
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
systemctl enable etcd
systemctl restart etcd"

            if remote_exec ${i} "${command}"; then
                success "${i} etcd service started"
            fi
        done
    fi

    if [ ${#master_node[@]} -eq 3 ]; then
        command="ETCDCTL_API=3 ${bin_path}/etcdctl \
--cacert=${cert_path}/etcd-ca.pem \
--cert=${cert_path}/etcd.pem \
--key=${cert_path}/etcd-key.pem \
--endpoints="https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379" \
endpoint status --write-out=table"

        # etcd 为 Type=notify 且 READY 需 raft 发布成员信息(quorum),
        # 三 master 首次启动用 --no-block, 这里轮询等待集群就绪
        for ((retry = 0; retry < 30; retry++)); do
            if remote_capture ${node_ip[0]} "${command}" >/dev/null; then
                success "etcd cluster started"
                return 0
            fi
            sleep 5
        done
        error "etcd cluster failed to become ready on ${node_ip[0]}"
    else
        command="ETCDCTL_API=3 ${bin_path}/etcdctl \
--cacert=${cert_path}/etcd-ca.pem \
--cert=${cert_path}/etcd.pem \
--key=${cert_path}/etcd-key.pem \
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
            command="cat > ${conf_path}/token.csv <<EOF
${kube_token},kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > ${systemd_path}/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${bin_path}/kube-apiserver \
--apiserver-count=3 \
--etcd-servers=https://${node_ip[0]}:2379,https://${node_ip[1]}:2379,https://${node_ip[2]}:2379 \
--etcd-cafile=${cert_path}/etcd-ca.pem \
--etcd-certfile=${cert_path}/etcd.pem \
--etcd-keyfile=${cert_path}/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction,DefaultTolerationSeconds,DefaultStorageClass \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${conf_path}/token.csv \
--kubelet-client-certificate=${cert_path}/kube-apiserver.pem \
--kubelet-client-key=${cert_path}/kube-apiserver-key.pem \
--tls-cert-file=${cert_path}/kube-apiserver.pem  \
--tls-private-key-file=${cert_path}/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${cert_path}/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${cert_path}/sa.key \
--service-account-key-file=${cert_path}/sa.pub \
--proxy-client-cert-file=${cert_path}/kube-apiserver.pem \
--proxy-client-key-file=${cert_path}/kube-apiserver-key.pem \
--requestheader-client-ca-file=${cert_path}/ca.pem \
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
systemctl enable kube-apiserver
systemctl restart kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "${i} kube-apiserver service started"
            fi
        done
    else
        for i in "${master_node[@]}"; do
            command="cat > ${conf_path}/token.csv <<EOF
${kube_token},kubelet-bootstrap,10001,\"system:kubelet-bootstrap\"
EOF
cat > ${systemd_path}/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target
Wants=etcd.service

[Service]
ExecStart=${bin_path}/kube-apiserver \
--apiserver-count=1 \
--etcd-servers=https://${node_ip[0]}:2379 \
--etcd-cafile=${cert_path}/etcd-ca.pem \
--etcd-certfile=${cert_path}/etcd.pem \
--etcd-keyfile=${cert_path}/etcd-key.pem \
--advertise-address=${i} \
--anonymous-auth=false \
--allow-privileged=true \
--service-cluster-ip-range=10.96.0.0/16 \
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction \
--authorization-mode=RBAC,Node \
--enable-bootstrap-token-auth=true \
--token-auth-file=${conf_path}/token.csv \
--kubelet-client-certificate=${cert_path}/kube-apiserver.pem \
--kubelet-client-key=${cert_path}/kube-apiserver-key.pem \
--tls-cert-file=${cert_path}/kube-apiserver.pem  \
--tls-private-key-file=${cert_path}/kube-apiserver-key.pem \
--tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
--client-ca-file=${cert_path}/ca.pem \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
--service-account-signing-key-file=${cert_path}/sa.key \
--service-account-key-file=${cert_path}/sa.pub \
--proxy-client-cert-file=${cert_path}/kube-apiserver.pem \
--proxy-client-key-file=${cert_path}/kube-apiserver-key.pem \
--requestheader-client-ca-file=${cert_path}/ca.pem \
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
systemctl enable kube-apiserver
systemctl restart kube-apiserver"

            if remote_exec ${i} "${command}"; then
                success "${i} kube-apiserver service started"
            fi
        done
    fi
}

function config_controller() {
    command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cert_path}/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${conf_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config set-credentials kube-controller-manager \
  --client-certificate=${cert_path}/kube-controller-manager.pem \
  --client-key=${cert_path}/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=${conf_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-controller-manager \
  --kubeconfig=${conf_path}/kube-controller-manager.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${conf_path}/kube-controller-manager.kubeconfig
cat > ${systemd_path}/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-controller-manager \
--bind-address=0.0.0.0 \
--kubeconfig=${conf_path}/kube-controller-manager.kubeconfig \
--allocate-node-cidrs=true \
--cluster-cidr=10.244.0.0/16 \
--service-cluster-ip-range=10.96.0.0/16 \
--cluster-signing-cert-file=${cert_path}/ca.pem \
--cluster-signing-key-file=${cert_path}/ca-key.pem \
--cluster-signing-duration=876000h0m0s \
--root-ca-file=${cert_path}/ca.pem \
--service-account-private-key-file=${cert_path}/sa.key \
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
systemctl enable kube-controller-manager
systemctl restart kube-controller-manager"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "${i} kube-controller-manager service started"
        fi
    done
}

function config_scheduler() {
    command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cert_path}/ca.pem \
  --embed-certs=true \
  --server=${apiserver_url} \
  --kubeconfig=${conf_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config set-credentials kube-scheduler \
  --client-certificate=${cert_path}/kube-scheduler.pem \
  --client-key=${cert_path}/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=${conf_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-scheduler \
  --kubeconfig=${conf_path}/kube-scheduler.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${conf_path}/kube-scheduler.kubeconfig
cat > ${systemd_path}/kube-scheduler.service << EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=${bin_path}/kube-scheduler \
--bind-address=0.0.0.0 \
--kubeconfig=${conf_path}/kube-scheduler.kubeconfig \
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
systemctl enable kube-scheduler
systemctl restart kube-scheduler"

    for i in "${master_node[@]}"; do
        if remote_exec ${i} "${command}"; then
            success "${i} kube-scheduler service started"
        fi
    done
}

function config_kubeconfig() {
    for i in "${master_node[@]}"; do
        command="${bin_path}/kubectl config set-cluster kubernetes \
  --certificate-authority=${cert_path}/ca.pem \
  --embed-certs=true \
  --server=https://${i}:6443 \
  --kubeconfig=${conf_path}/admin.kubeconfig
${bin_path}/kubectl config set-credentials kubernetes-admin \
  --client-certificate=${cert_path}/admin.pem \
  --client-key=${cert_path}/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=${conf_path}/admin.kubeconfig
${bin_path}/kubectl config set-context default \
  --cluster=kubernetes \
  --user=kubernetes-admin \
  --kubeconfig=${conf_path}/admin.kubeconfig
${bin_path}/kubectl config use-context default \
  --kubeconfig=${conf_path}/admin.kubeconfig
mkdir -p ~/.kube && \cp ${conf_path}/admin.kubeconfig ~/.kube/config
${bin_path}/kubectl get cs"
        if remote_exec ${i} "${command}"; then
            success "${i} kubeconfig setted"
        fi
    done

    scp -i ${ssh_key} -P ${ssh_port} ${ssh_user}@${node_ip[0]}:${conf_path}/admin.kubeconfig ${run_path}/admin.kubeconfig

    if ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig get cs; then
        success "local kubeconfig setted"
    fi
}

