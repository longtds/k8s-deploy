# shellcheck shell=bash
# metallb 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "metallb 已就绪, 配置地址池后即可使用 LoadBalancer 类型 Service(地址段按实际网络修改):
  kubectl apply -f - <<EOF
  apiVersion: metallb.io/v1beta1
  kind: IPAddressPool
  metadata:
    name: default-pool
    namespace: ${plugin_namespace}
  spec:
    addresses:
    - 192.168.121.240-192.168.121.250
  ---
  apiVersion: metallb.io/v1beta1
  kind: L2Advertisement
  metadata:
    name: default
    namespace: ${plugin_namespace}
  spec:
    ipAddressPools:
    - default-pool
  EOF
higress 网关可随后将 higress-gateway Service 改为 LoadBalancer 类型以获得 EXTERNAL-IP。"
}
