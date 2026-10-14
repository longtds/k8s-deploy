# shellcheck shell=bash
# higress 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

# higress 与 istio 插件互斥: 两者都基于 istio 控制面, 且都声明
# envoyfilters.networking.istio.io CRD。共存会互相覆盖该 CRD, 卸载任一方时
# 删除该 CRD 又会破坏另一方。以 istio 独有的 CRD 判定其已安装。
function plugin_pre_install() {
    if plugin_kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
        _plugin_fail "higress conflicts with an installed istio plugin (shared CRD envoyfilters.networking.istio.io and istio control plane); remove it first: ./deploy.sh plugin remove istio" || return 1
        return 1
    fi
}

function plugin_post_install() {
    note "higress console 管理界面(默认账号 admin/higress, 请登录后尽快修改口令):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig -n ${plugin_namespace} port-forward svc/higress-console 8080:8080

higress gateway(NodePort, 按需改用 LoadBalancer):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig -n ${plugin_namespace} get svc higress-gateway

路由治理: 通过管理界面的 路由/域名/插件 配置, 或 kubectl 应用 higress 的 Ingress/CRD(WasmPlugin 等)。"
}
