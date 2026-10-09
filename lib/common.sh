# shellcheck shell=bash

set +e
set -o noglob

bold=$(tput bold)
underline=$(tput sgr 0 1)
reset=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 76)
white=$(tput setaf 7)
tan=$(tput setaf 202)
blue=$(tput setaf 25)

underline() {
    printf "${underline}${bold}%s${reset}\n" "$@"
}
h1() {
    printf "\n${underline}${bold}${blue}%s${reset}\n" "$@"
}
h2() {
    printf "\n${underline}${bold}${white}%s${reset}\n" "$@"
}
debug() {
    printf "${white}%s${reset}\n" "$@"
}
info() {
    printf "${white}➜ %s${reset}\n" "$@"
}
success() {
    printf "$(TZ=UTC-8 date +%Y-%m-%d" "%H:%M:%S) ${green}✔ %s${reset}\n" "$@"
}
error() {
    printf "${red}✖ %s${reset}\n" "$@"
    exit 2
}
warn() {
    printf "${tan}➜ %s${reset}\n" "$@"
}
bold() {
    printf "${bold}%s${reset}\n" "$@"
}
note() {
    printf "\n${underline}${bold}${blue}Note:${reset} ${blue}%s${reset}\n" "$@"
}

# 轮询等待直到检查命令成功; 超时返回非零(由调用方输出现场并 error), 避免节点异常时无限挂起
# 用法: wait_until <描述> <最大尝试次数> <间隔秒> <检查命令及参数...>
# 例:   wait_until "nodes ready" 90 10 bash -c '[ "$(kubectl get nodes --no-headers | wc -l)" -eq 3 ] \
#           || { kubectl get node; error "nodes not ready"; }
function wait_until() {
    local desc=$1 max=$2 interval=$3
    shift 3
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ ${attempt} -ge ${max} ]; then
            warn "timeout after ${max} attempts (${interval}s each) waiting for: ${desc}"
            return 1
        fi
        sleep "${interval}"
        attempt=$((attempt + 1))
    done
}

set -e
