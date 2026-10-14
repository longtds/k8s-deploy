# shellcheck shell=bash
# loki 插件钩子: 安装/卸载的自定义逻辑; 通用步骤由 lib/plugin.sh 引擎完成。
# 可用变量: plugin_dir/plugin_version/plugin_namespace, 可用命令: plugin_kubectl

function plugin_post_install() {
    note "日志查询 PromQL(LogQL) 示例:
  {job=\"varlogs\"} |= \"error\"
  {namespace=\"default\"}

Grafana 集成(prometheus 插件已装时自动注册数据源, 未装可手动添加):
  URL: http://loki.${plugin_namespace}.svc.cluster.local:3100"
}

# prometheus 插件的 Grafana 通过 sidecar 自动加载数据源 ConfigMap; 仅当 monitoring
# 命名空间存在时 best-effort 创建, 卸载时随之清理
function _plugin_loki_datasource() {
    printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' \
        'metadata:' '  name: loki-datasource' '  namespace: monitoring' \
        '  labels:' '    grafana_datasource: "1"' \
        'data:' '  loki-datasource.yaml: |' \
        '    apiVersion: 1' '    datasources:' \
        '      - name: Loki' '        type: loki' '        access: proxy' \
        '        url: http://loki.logging.svc.cluster.local:3100' \
        '        isDefault: false'
}

function plugin_ready() {
    if plugin_kubectl get ns monitoring >/dev/null 2>&1; then
        if _plugin_loki_datasource | plugin_kubectl apply -f - >/dev/null; then
            success "Loki datasource registered into Grafana (namespace monitoring)"
        else
            warn "register Loki datasource into Grafana failed, add it manually"
        fi
    fi
}

function plugin_pre_remove() {
    if plugin_kubectl get ns monitoring >/dev/null 2>&1; then
        plugin_kubectl -n monitoring delete configmap loki-datasource --ignore-not-found >/dev/null 2>&1 || true
    fi
}
