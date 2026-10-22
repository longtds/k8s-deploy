# shellcheck shell=bash
# cert-manager 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "cert-manager 已就绪, 创建 ClusterIssuer 后即可为 Ingress/Gateway 自动签发证书, 自签示例:
  kubectl apply -f - <<EOF
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: selfsigned
  spec:
    selfSigned: {}
  EOF
Ingress 加注 cert-manager.io/cluster-issuer: selfsigned 即可自动签发。
离线环境请使用 selfSigned/CA/Vault(内网) 类型 Issuer; ACME(Let's Encrypt) 需公网可达。"
}
