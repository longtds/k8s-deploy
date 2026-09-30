# shellcheck shell=bash

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

    command1="mkdir -p ${cert_path}"

    # Update ca-trust
    command2="if [ -d /etc/pki/ca-trust ]; then
    if update-ca-trust force-enable; then
        \cp -f ${cert_path}/ca.pem /etc/pki/ca-trust/source/anchors/k8s-ca.pem
        \cp -f ${cert_path}/etcd-ca.pem /etc/pki/ca-trust/source/anchors/etcd-ca.pem
        update-ca-trust extract
    else
        cat ${cert_path}/ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
        cat ${cert_path}/etcd-ca.pem >>/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    fi
fi
if [ -d /usr/local/share/ca-certificates ]; then
    if [ ! -f /usr/local/share/ca-certificates/k8s.crt ];then
        \cp -f ${cert_path}/ca.pem /usr/local/share/ca-certificates/k8s.crt
        \cp -f ${cert_path}/etcd-ca.pem /usr/local/share/ca-certificates/etcd.crt
        update-ca-certificates
    fi
fi"

    for ((i = 0; i < num; i++)); do
        if remote_exec ${args[${i}]} "${command1}"; then
            success "${args[${i}]} ${cert_path} created"
        fi

        if remote_cp "${pki_path}" "${args[${i}]}:${conf_path}" -r; then
            success "${args[${i}]} pki copied"
        fi

        if remote_exec ${args[${i}]} "${command2}"; then
            success "${args[${i}]} update-ca-trust"
        fi
    done

}

