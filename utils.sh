#/bin/bash
# This is a collection of useful shell scripts
if [ -f config.ini ]; then
    source config.ini
else
    error "file config.ini not found."
fi

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

set -e

function download() {
    file_url="$1"
    file_name="$2"

    if [ -f "${download_path}/${file_name}" ]; then
        note "${download_path}/${file_name} exists"
        return 0
    fi

    note "download ${file_url}"
    if curl -L --progress-bar "${file_url}" -o "${download_path}/${file_name}"; then
        success "download ${file_name} successfully"
    else
        error "download ${file_name} failed"
    fi
}

function sync_image() {
    src_image="$1"
    dst_image="$2"
    if docker pull --platform linux/${arch_name} "${src_image}";then
        docker tag "${src_image}" "${dst_image}" 
        if ! docker push "${dst_image}";then 
            error "push ${dst_image} failed"
        fi
    else
        error "pull ${src_image} failed"
    fi
}
