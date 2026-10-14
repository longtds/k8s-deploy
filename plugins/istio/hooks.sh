# shellcheck shell=bash
# istio 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

# istio 与 higress 插件互斥: 两者都基于 istio 控制面, 且都声明
# envoyfilters.networking.istio.io CRD。以 higress 独有的 CRD 判定其已安装。
function plugin_pre_install() {
    if plugin_kubectl get crd mcpbridges.networking.higress.io >/dev/null 2>&1; then
        _plugin_fail "istio conflicts with an installed higress plugin (shared CRD envoyfilters.networking.istio.io and istio control plane); remove it first: ./deploy.sh plugin remove higress" || return 1
        return 1
    fi
}

function plugin_post_install() {
    note "启用命名空间 sidecar 自动注入(按需执行):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig label ns <namespace> istio-injection=enabled

Ingress Gateway(cluster IP, 可按需改为 NodePort):
  ${pkg_path}/bin/kubectl --kubeconfig ${run_path}/admin.kubeconfig -n ${plugin_namespace} get svc istio-ingressgateway

路由治理示例(VirtualService/DestinationRule)与流量策略由 istio CRD 提供, 参考 istio 官方文档。"
}
