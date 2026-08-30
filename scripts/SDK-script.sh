#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES_REPO="${PACKAGES_REPO:-https://github.com/laipeng668/packages}"
LUCI_REPO="${LUCI_REPO:-https://github.com/laipeng668/luci}"
GECOOSAC_REPO="${GECOOSAC_REPO:-https://github.com/laipeng668/luci-app-gecoosac}"
AURORA_REPO="${AURORA_REPO:-https://github.com/eamonxg/luci-theme-aurora}"
AURORA_CONFIG_REPO="${AURORA_CONFIG_REPO:-https://github.com/eamonxg/luci-app-aurora-config}"
OPENLIST2_REPO="${OPENLIST2_REPO:-https://github.com/laipeng668/luci-app-openlist2}"
DJONEHUB_REPO="${DJONEHUB_REPO:-https://github.com/563617356/luci-app-djonehub}"
VOHIVE_REPO="${VOHIVE_REPO:-https://github.com/563617356/luci-app-vohive}"
# djonehub-core / vohive-core 只打包预编译二进制，仓库里的 files/ 目录是空的（仅 .gitkeep），
# 必须在编译前把对应架构的二进制下载进去，否则 install 阶段会报
# "install: cannot stat './files/djonehub-arm64': No such file or directory"。
DJONEHUB_RELEASE_REPO="${DJONEHUB_RELEASE_REPO:-https://github.com/563617356/djonehub-release}"
VOHIVE_RELEASE_REPO="${VOHIVE_RELEASE_REPO:-https://github.com/iniwex5/vohive-release}"
DJONEHUB_CORE_VERSION="${DJONEHUB_CORE_VERSION:-v1.5.2}"
# vohive-core/Makefile 的默认值 v1.5.4 在 vohive-release 上没有对应资源，
# 上游 release.yml 用的也是 v9.9.9，取其为准，并保留"缺资源回退 Latest"的逻辑。
VOHIVE_CORE_VERSION="${VOHIVE_CORE_VERSION:-v9.9.9}"
CORE_VARIANT_ARCHS="${CORE_VARIANT_ARCHS:-arm64 amd64 armv7}"
# feed 分支回退表，格式 "<原分支>=<备选分支>"，空格分隔。
FEED_BRANCH_FALLBACKS="${FEED_BRANCH_FALLBACKS:-frp-binary-toml=frp-binary frp-toml=frp}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
OPENWRT_TARGET_PROFILE="${OPENWRT_TARGET_PROFILE:-}"
OPENWRT_DOWNLOADS_BASE_URL="${OPENWRT_DOWNLOADS_BASE_URL:-https://downloads.openwrt.org}"
OPENWRT_SDK_VERSION="${OPENWRT_SDK_VERSION:-${SDK_VERSION:-main}}"
OPENWRT_SDK_BASE_URL="${OPENWRT_SDK_BASE_URL:-}"
SDK_URL="${SDK_URL:-}"
PACKAGE_CONFIG_FILES="${PACKAGE_CONFIG_FILES:-${CONFIG_FILES:-configs/x86-64.config configs/Packages.config}}"
unset CONFIG_FILES
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${SDK_ROOT:-$RUNNER_TEMP/openwrt-sdk}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts/packages}"
PACKAGE_ARCH_NAME="${PACKAGE_ARCH_NAME:-$OPENWRT_TARGET-$OPENWRT_SUBTARGET}"
PACKAGE_SELECTED_ARCH="${PACKAGE_SELECTED_ARCH:-$PACKAGE_ARCH_NAME}"
PACKAGE_SELECTION="${PACKAGE_SELECTION:-${PACKAGE_NAME:-all}}"
SDK_ARCHIVE="$RUNNER_TEMP/openwrt-sdk.tarball"
SPARSE_ROOT="$RUNNER_TEMP/openwrt-sparse-clone"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

COMPILE_TARGETS=()
CONFIG_FILE_LIST=()
ARTIFACT_PACKAGE_NAMES=()
# 预编译核心二进制下载失败/校验不通过的包名，例如 vohive-core-arm64。
# 这些变体会在 defconfig 之前被显式关掉，避免编译出坏包或直接构建失败。
SKIPPED_CORE_PACKAGES=()

log() {
  printf '\n==> %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_package_selection() {
  local selection="${1:-all}"

  selection="${selection,,}"
  case "$selection" in
    "" | all | "全部")
      printf 'all\n'
      ;;
    frp | nginx | luci-app-aria2 | luci-app-frpc | luci-app-frps | luci-app-gecoosac | luci-app-openlist2 | luci-app-djonehub | luci-app-vohive | luci-theme-aurora)
      printf '%s\n' "$selection"
      ;;
    aria2 | ariang)
      printf 'luci-app-aria2\n'
      ;;
    frpc)
      printf 'luci-app-frpc\n'
      ;;
    frps)
      printf 'luci-app-frps\n'
      ;;
    frp-binary-toml | frp-toml)
      printf 'frp\n'
      ;;
    nginx-full | nginx-ssl)
      printf 'nginx\n'
      ;;
    gecoosac)
      printf 'luci-app-gecoosac\n'
      ;;
    openlist | openlist2)
      printf 'luci-app-openlist2\n'
      ;;
    luci-app-openlist)
      printf 'luci-app-openlist2\n'
      ;;
    *)
      die "Unsupported PACKAGE_SELECTION: ${1:-} (supported: all, nginx, luci-app-aria2, luci-app-frpc, luci-app-frps, luci-app-gecoosac, luci-app-openlist2, luci-app-djonehub, luci-app-vohive, luci-theme-aurora; legacy aliases: aria2, ariang, frp, gecoosac, openlist2)"
      ;;
  esac
}

normalize_sdk_version() {
  local version="${1:-main}"

  version="${version,,}"
  case "$version" in
    "" | main | snapshot | snapshots | master)
      printf 'main\n'
      ;;
    23.05 | 24.10 | 25.12)
      printf '%s\n' "$version"
      ;;
    *)
      die "Unsupported OPENWRT_SDK_VERSION: ${1:-} (supported: main, 23.05, 24.10, 25.12)"
      ;;
  esac
}

load_inline_target_profile() {
  local profile="${1:-}"

  [ -n "$profile" ] || return 0

  case "$profile" in
    rax3000m | cmcc-rax3000m | cmcc_rax3000m)
      [ "$OPENWRT_TARGET" = mediatek ] && [ "$OPENWRT_SUBTARGET" = filogic ] ||
        die "OPENWRT_TARGET_PROFILE=$profile requires OPENWRT_TARGET=mediatek and OPENWRT_SUBTARGET=filogic"
      cat >> "$SDK_ROOT/.config" <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m=y
EOF
      ;;
    *)
      die "Unsupported OPENWRT_TARGET_PROFILE: $profile (supported: rax3000m)"
      ;;
  esac
}

selection_is_all() {
  [ "$PACKAGE_SELECTION" = all ]
}

selection_is() {
  [ "$PACKAGE_SELECTION" = "$1" ]
}

selection_in() {
  local package_name

  selection_is_all && return 0

  for package_name in "$@"; do
    selection_is "$package_name" && return 0
  done

  return 1
}

resolve_sdk_url() {
  local sdk_base_url
  local sdk_href

  if [ -n "$SDK_URL" ]; then
    printf '%s\n' "$SDK_URL"
    return
  fi

  sdk_base_url="$(resolve_sdk_base_url)"
  log "Resolve OpenWrt $OPENWRT_SDK_VERSION SDK for $OPENWRT_TARGET/$OPENWRT_SUBTARGET"
  sdk_href="$(
    curl -fsSL "${sdk_base_url%/}/" |
      grep -oE 'href="[^"]*openwrt-sdk-[^"]+\.tar\.(xz|zst|gz)"' |
      sed -E 's/^href="([^"]+)"/\1/' |
      head -n 1 || true
  )"

  [ -n "$sdk_href" ] || die "OpenWrt SDK archive was not found at $sdk_base_url"

  case "$sdk_href" in
    http://* | https://*)
      printf '%s\n' "$sdk_href"
      ;;
    /*)
      printf '%s%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$sdk_href"
      ;;
    *)
      printf '%s/%s\n' "${sdk_base_url%/}" "$sdk_href"
      ;;
  esac
}

resolve_sdk_base_url() {
  local release_version
  local sdk_version

  if [ -n "$OPENWRT_SDK_BASE_URL" ]; then
    printf '%s\n' "$OPENWRT_SDK_BASE_URL"
    return
  fi

  sdk_version="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"
  if [ "$sdk_version" = main ]; then
    printf '%s/snapshots/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
    return
  fi

  release_version="$(resolve_latest_release_version "$sdk_version")"
  printf '%s/releases/%s/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$release_version" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
}

resolve_latest_release_version() {
  local release_version
  local series="$1"

  release_version="$(
    curl -fsSL "${OPENWRT_DOWNLOADS_BASE_URL%/}/releases/" |
      grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' |
      sed -E 's/^href="([^"]+)\/"/\1/' |
      grep -E "^${series//./\\.}(\\.[0-9]+)?$" |
      sort -V |
      tail -n 1 || true
  )"

  [ -n "$release_version" ] || die "OpenWrt release series was not found: $series"
  printf '%s\n' "$release_version"
}

download_sdk() {
  local resolved_url="$1"

  case "$resolved_url" in
    file://*)
      cp "${resolved_url#file://}" "$SDK_ARCHIVE"
      ;;
    /*)
      cp "$resolved_url" "$SDK_ARCHIVE"
      ;;
    *)
      curl -fsSL --retry 3 "$resolved_url" -o "$SDK_ARCHIVE"
      ;;
  esac
}

extract_sdk() {
  local resolved_url="$1"
  local archive_name
  archive_name="${resolved_url%%\?*}"

  mkdir -p "$SDK_ROOT"
  case "$archive_name" in
    *.tar.zst | *.tzst)
      tar --zstd -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.xz | *.txz)
      tar -xJf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.gz | *.tgz)
      tar -xzf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *)
      tar -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
  esac
}

resolve_feed_branch() {
  # 上游 feed 仓库会重命名分支（frp-binary-toml -> frp-binary、frp-toml -> frp），
  # 一旦改名整条 CI 就会在 clone 阶段直接挂掉。这里按 FEED_BRANCH_FALLBACKS
  # 做一次"原分支不存在就用备选分支"的兜底。
  local repourl="$1"
  local branch="$2"
  local pair
  local fallback=""

  for pair in $FEED_BRANCH_FALLBACKS; do
    if [ "${pair%%=*}" = "$branch" ]; then
      fallback="${pair#*=}"
      break
    fi
  done

  [ -n "$fallback" ] || {
    printf '%s\n' "$branch"
    return 0
  }

  if git ls-remote --heads --exit-code "$repourl" "$branch" >/dev/null 2>&1; then
    printf '%s\n' "$branch"
    return 0
  fi

  log "Feed branch $branch not found in $repourl, falling back to $fallback"
  printf '%s\n' "$fallback"
}

git_sparse_clone() {
  local branch
  local repourl="$2"
  local target_root="$3"
  local repodir
  local sparse_path
  branch="$(resolve_feed_branch "$repourl" "$1")"
  shift 3

  repodir="$SPARSE_ROOT/$(basename "${repourl%.git}")-${branch//\//-}"
  rm -rf "$repodir"
  git clone \
    --depth=1 \
    --no-tags \
    -b "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl" \
    "$repodir"

  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )

  for sparse_path in "$@"; do
    local source_path="$repodir/$sparse_path"
    local target_path

    target_path="$SDK_ROOT/$target_root/$sparse_path"

    [ -d "$source_path" ] || die "Sparse package directory not found: $source_path"
    if [ ! -f "$source_path/Makefile" ] &&
      [ -z "$(find "$source_path" -mindepth 2 -maxdepth 2 -type f -name Makefile -print -quit)" ]; then
      die "Package Makefile not found under: $source_path"
    fi

    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  done

  rm -rf "$repodir"
}

git_clone_package_repo() {
  local repourl="$1"
  local target_path="$2"
  local makefile_path
  shift 2

  rm -rf "$target_path"
  git clone \
    --depth=1 \
    --no-tags \
    "$repourl" \
    "$target_path"

  for makefile_path in "$@"; do
    [ -f "$target_path/$makefile_path" ] || die "Package Makefile not found: $target_path/$makefile_path"
  done
}

remove_builtin_packages() {
  rm -rf \
    "$SDK_ROOT/feeds/packages/net/aria2" \
    "$SDK_ROOT/feeds/packages/net/ariang" \
    "$SDK_ROOT/feeds/packages/net/frp" \
    "$SDK_ROOT/feeds/packages/lang/golang" \
    "$SDK_ROOT/feeds/packages/net/nginx" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frpc" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frps"
}

load_custom_packages() {
  mkdir -p "$SPARSE_ROOT"

  git_sparse_clone aria2 "$PACKAGES_REPO" feeds/packages net/aria2
  git_sparse_clone ariang "$PACKAGES_REPO" feeds/packages net/ariang
  git_sparse_clone master "$PACKAGES_REPO" feeds/packages lang/golang
  git_sparse_clone frp-binary-toml "$PACKAGES_REPO" feeds/packages net/frp
  git_sparse_clone nginx "$PACKAGES_REPO" feeds/packages net/nginx
  git_sparse_clone frp-toml "$LUCI_REPO" feeds/luci \
    applications/luci-app-frpc \
    applications/luci-app-frps
  git_clone_package_repo "$GECOOSAC_REPO" "$SDK_ROOT/package/luci-app-gecoosac" \
    gecoosac/Makefile \
    luci-app-gecoosac/Makefile
  git_clone_package_repo "$AURORA_REPO" "$SDK_ROOT/package/luci-theme-aurora" Makefile
  git_clone_package_repo "$AURORA_CONFIG_REPO" "$SDK_ROOT/package/luci-app-aurora-config" Makefile
  git_clone_package_repo "$OPENLIST2_REPO" "$SDK_ROOT/package/openlist2" \
    openlist2/Makefile \
    luci-app-openlist2/Makefile
  # DJOneHub / VoHive（563617356 自有仓库，单独编译用）
  git_sparse_clone main "$DJONEHUB_REPO" package djonehub-core luci-app-djonehub
  git_sparse_clone main "$VOHIVE_REPO" package vohive-core luci-app-vohive
}

latest_github_release_tag() {
  local api_url="$1"
  local tag=""

  tag="$(curl -fsSL --connect-timeout 20 --retry 3 "$api_url" |
    python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)" || tag=""

  [ -n "$tag" ] && printf '%s\n' "$tag"
}

is_elf_binary() {
  # release 资源可能被上游替换成占位文本（出现过 12 字节的"江湖再见"），
  # 这种文件 install 阶段不会报错，但打出来的包是坏的，所以必须校验 ELF 魔数。
  local target="$1"
  local magic

  [ -s "$target" ] || return 1
  magic="$(head -c 4 "$target" | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ]
}

fetch_core_binary() {
  # $1=release 仓库 URL  $2=tag  $3=资源名前缀  $4=架构  $5=目标文件路径
  # 成功返回 0；下载失败或产物不是 ELF 返回 1（调用方负责跳过对应变体）。
  local release_repo="$1"
  local version="$2"
  local prefix="$3"
  local arch="$4"
  local target="$5"
  local asset
  local url
  local api_url
  local latest

  asset="${prefix}_${version}_linux_${arch}"
  url="${release_repo}/releases/download/${version}/${asset}"

  if ! curl -fL --connect-timeout 20 --retry 3 "$url" -o "$target"; then
    rm -f "$target"
    return 1
  fi

  # 指定 tag 的下载到了但不是合法 ELF（缺资源 / 被占位文件替换）时，
  # 回退到仓库 Latest，避免单个历史 tag 的问题让整个构建失败。
  if ! is_elf_binary "$target"; then
    api_url="https://api.github.com/repos/${release_repo#https://github.com/}/releases/latest"
    latest="$(latest_github_release_tag "$api_url")"

    if [ -n "$latest" ] && [ "$latest" != "$version" ]; then
      log "Core asset $asset is not a valid binary, fall back to latest release $latest"
      version="$latest"
      asset="${prefix}_${version}_linux_${arch}"
      url="${release_repo}/releases/download/${version}/${asset}"

      if ! curl -fL --connect-timeout 20 --retry 3 "$url" -o "$target"; then
        rm -f "$target"
        return 1
      fi
    fi
  fi

  if ! is_elf_binary "$target"; then
    log "Core asset $asset is not a valid ELF binary, skipping ${prefix}-core-${arch}"
    rm -f "$target"
    return 1
  fi

  chmod 0755 "$target"
  log "Fetched ${asset} ($(wc -c <"$target" | tr -d ' ') bytes) -> $(basename "$target")"
}

fetch_prebuilt_core_binaries() {
  # djonehub-core / vohive-core 只做二进制打包，仓库里的 files/ 只有 .gitkeep，
  # 必须由 CI 在编译前把对应架构的预编译二进制拉进 files/。
  local arch
  local files_dir

  if selection_in luci-app-djonehub; then
    files_dir="$SDK_ROOT/package/djonehub-core/files"
    mkdir -p "$files_dir"
    for arch in $CORE_VARIANT_ARCHS; do
      fetch_core_binary "$DJONEHUB_RELEASE_REPO" "$DJONEHUB_CORE_VERSION" \
        djonehub "$arch" "$files_dir/djonehub-${arch}" ||
        SKIPPED_CORE_PACKAGES+=("djonehub-core-${arch}")
    done
  fi

  if selection_in luci-app-vohive; then
    files_dir="$SDK_ROOT/package/vohive-core/files"
    mkdir -p "$files_dir"
    for arch in $CORE_VARIANT_ARCHS; do
      fetch_core_binary "$VOHIVE_RELEASE_REPO" "$VOHIVE_CORE_VERSION" \
        vohive "$arch" "$files_dir/vohive-${arch}" ||
        SKIPPED_CORE_PACKAGES+=("vohive-core-${arch}")
    done
  fi

  if [ "${#SKIPPED_CORE_PACKAGES[@]}" -gt 0 ]; then
    log "Unavailable core variants: ${SKIPPED_CORE_PACKAGES[*]}"
  fi
}

core_variant_available() {
  # 判断 <prefix>-core 是否至少有一个"二进制可用且已在 .config 里启用"的变体。
  local prefix="$1"
  local arch
  local skipped

  for arch in $CORE_VARIANT_ARCHS; do
    for skipped in ${SKIPPED_CORE_PACKAGES[@]+"${SKIPPED_CORE_PACKAGES[@]}"}; do
      [ "$skipped" != "${prefix}-core-${arch}" ] || continue 2
    done
    config_package_enabled "${prefix}-core-${arch}" && return 0
  done

  return 1
}

disable_unavailable_core_variants() {
  # 预编译二进制下载失败/校验不通过的变体，必须在 defconfig 之前显式关掉，
  # 否则 install 阶段会因 files/ 里没有对应二进制而失败。
  local package_name

  for package_name in ${SKIPPED_CORE_PACKAGES[@]+"${SKIPPED_CORE_PACKAGES[@]}"}; do
    set_config_symbol "CONFIG_PACKAGE_${package_name}" "$SDK_ROOT/.config"
    log "Disabled unavailable core variant: $package_name"
  done
}

set_config_symbol() {
  # 幂等地把 .config 里的某个符号设成 n：删掉已有写法再补一行 VAR=n。
  # 比 sed 就地替换更可靠——符号原本不在 .config 里时 sed 是无操作，
  # 而 defconfig 之后 make 会重新解析并把它恢复成 y。
  local var="$1"
  local config_file="$2"

  [ -f "$config_file" ] || die "Config file not found: $config_file"
  sed -i "/^${var}=/d; /^# ${var} is not set$/d" "$config_file"
  printf '%s=n\n' "$var" >> "$config_file"
}

select_arch_specific_core_variants() {
  # djonehub-core / vohive-core 各提供 arm64/amd64/armv7 三个预编译变体（互相 CONFLICTS）。
  # 仅启用当前目标架构对应的变体，避免把其它架构的预编译二进制打包进当前架构的产物。
  #
  # 注意事项：这三个变体互相 CONFLICTS，OpenWrt 的 package-metadata.pl 会把 CONFLICTS
  # 展开成 "depends on m || (PACKAGE_x != y)"，从而构成 kconfig 循环依赖
  # （日志里的 "recursive dependency detected"）。循环里的符号无法在 defconfig 之后
  # 再改值——下一次 make 会重新跑 defconfig 并把它改回来。因此本函数必须在
  # make defconfig **之前** 调用，让 kconfig 从一开始就用 arm64=n / amd64=n 求解。
  local enable_amd64="n"

  [ "$OPENWRT_TARGET" = "x86" ] && enable_amd64="y"

  if [ "$enable_amd64" = "y" ]; then
    set_config_symbol "CONFIG_PACKAGE_djonehub-core-arm64" "$SDK_ROOT/.config"
    set_config_symbol "CONFIG_PACKAGE_vohive-core-arm64" "$SDK_ROOT/.config"
  else
    set_config_symbol "CONFIG_PACKAGE_djonehub-core-amd64" "$SDK_ROOT/.config"
    set_config_symbol "CONFIG_PACKAGE_vohive-core-amd64" "$SDK_ROOT/.config"
  fi

  log "Core variant selection: OPENWRT_TARGET=$OPENWRT_TARGET enable_amd64=$enable_amd64"
}

prune_luci_translations() {
  local lang_dir
  local lang_name
  local po_dir
  local removed_count=0
  local root_dir

  for root_dir in \
    "$SDK_ROOT/package/luci-app-gecoosac" \
    "$SDK_ROOT/package/luci-app-aurora-config" \
    "$SDK_ROOT/package/luci-theme-aurora" \
    "$SDK_ROOT/package/roc" \
    "$SDK_ROOT/package/feeds/luci" \
    "$SDK_ROOT/feeds/luci/applications"; do
    [ -d "$root_dir" ] || continue

    while IFS= read -r -d '' po_dir; do
      while IFS= read -r -d '' lang_dir; do
        lang_name="$(basename "$lang_dir")"
        case "$lang_name" in
          templates | zh_Hans | zh_Hant)
            ;;
          *)
            rm -rf "$lang_dir"
            removed_count=$((removed_count + 1))
            ;;
        esac
      done < <(find "$po_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(find "$root_dir" -type d -name po -print0)
  done

  log "Pruned LuCI translations: kept zh_Hans and zh_Hant, removed $removed_count other language directories"
}

normalize_config_files() {
  printf '%s\n' "$PACKAGE_CONFIG_FILES" |
    sed -e 's/\r$//' -e 's/#.*$//' |
    tr ',[:space:]' '\n' |
    sed -e '/^$/d'
}

load_config_files() {
  local config_file
  local source_file

  : > "$SDK_ROOT/.config"
  load_inline_target_profile "$OPENWRT_TARGET_PROFILE"
  mapfile -t CONFIG_FILE_LIST < <(normalize_config_files)

  [ "${#CONFIG_FILE_LIST[@]}" -gt 0 ] || die "PACKAGE_CONFIG_FILES did not contain any config file"

  for config_file in "${CONFIG_FILE_LIST[@]}"; do
    if [ -f "$config_file" ]; then
      source_file="$config_file"
    else
      source_file="$WORKSPACE/$config_file"
    fi

    [ -f "$source_file" ] || die "Config file not found: $config_file"
    cat "$source_file" >> "$SDK_ROOT/.config"
    printf '\n' >> "$SDK_ROOT/.config"
  done
}

config_package_enabled() {
  local package_name="$1"

  grep -Eq "^CONFIG_PACKAGE_${package_name}=(y|m)$" "$SDK_ROOT/.config"
}

add_compile_target() {
  local compile_target="$1"
  local existing_target

  for existing_target in "${COMPILE_TARGETS[@]}"; do
    [ "$existing_target" != "$compile_target" ] || return
  done

  COMPILE_TARGETS+=("$compile_target")
}

add_artifact_package() {
  local package_name="$1"
  local existing_package

  for existing_package in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    [ "$existing_package" != "$package_name" ] || return
  done

  ARTIFACT_PACKAGE_NAMES+=("$package_name")
}

add_luci_i18n_packages() {
  local app_name="$1"

  add_artifact_package "luci-i18n-${app_name}-zh-cn"
  add_artifact_package "luci-i18n-${app_name}-zh-tw"
}

generate_artifact_filters() {
  ARTIFACT_PACKAGE_NAMES=()

  if selection_in luci-app-aria2 && {
    config_package_enabled aria2 ||
      config_package_enabled luci-app-aria2
  }; then
    add_artifact_package aria2
  fi

  if selection_in luci-app-aria2 && config_package_enabled ariang; then
    add_artifact_package ariang
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2; then
    add_artifact_package luci-app-aria2
    add_luci_i18n_packages aria2
  fi

  if { selection_in frp && config_package_enabled frpc; } ||
    { selection_in luci-app-frpc && {
      config_package_enabled frpc ||
        config_package_enabled luci-app-frpc
    }; }; then
    add_artifact_package frpc
  fi

  if { selection_in frp && config_package_enabled frps; } ||
    { selection_in luci-app-frps && {
      config_package_enabled frps ||
        config_package_enabled luci-app-frps
    }; }; then
    add_artifact_package frps
  fi

  if selection_in frp luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_artifact_package luci-app-frpc
    add_luci_i18n_packages frpc
  fi

  if selection_in frp luci-app-frps && config_package_enabled luci-app-frps; then
    add_artifact_package luci-app-frps
    add_luci_i18n_packages frps
  fi

  selection_in nginx && config_package_enabled nginx && add_artifact_package nginx
  selection_in nginx && config_package_enabled nginx-full && add_artifact_package nginx-full
  selection_in nginx && config_package_enabled nginx-ssl && add_artifact_package nginx-ssl

  if selection_in luci-app-openlist2 && {
    config_package_enabled openlist2 ||
      config_package_enabled luci-app-openlist2
  }; then
    add_artifact_package openlist2
  fi

  if selection_in luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_artifact_package gecoosac
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_artifact_package luci-app-gecoosac
    add_luci_i18n_packages gecoosac
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_artifact_package luci-app-openlist2
    add_luci_i18n_packages openlist2
  fi

  if selection_in luci-theme-aurora; then
    config_package_enabled luci-theme-aurora && add_artifact_package luci-theme-aurora
    if config_package_enabled luci-app-aurora-config; then
      add_artifact_package luci-app-aurora-config
      add_luci_i18n_packages aurora-config
    fi
  fi

  if selection_in luci-app-djonehub && core_variant_available djonehub; then
    add_artifact_package djonehub-core
  fi

  if selection_in luci-app-djonehub && config_package_enabled luci-app-djonehub; then
    add_artifact_package luci-app-djonehub
  fi

  if selection_in luci-app-vohive && core_variant_available vohive; then
    add_artifact_package vohive-core
  fi

  if selection_in luci-app-vohive && config_package_enabled luci-app-vohive; then
    add_artifact_package luci-app-vohive
  fi

  [ "${#ARTIFACT_PACKAGE_NAMES[@]}" -gt 0 ] || die "No package artifact filters were generated for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

artifact_package_allowed() {
  local package_file_name="$1"
  local package_name

  for package_name in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    package_file_matches_name "$package_file_name" "$package_name" && return 0
  done

  return 1
}

package_file_matches_name() {
  local package_file_name="$1"
  local package_name="$2"

  case "$package_file_name" in
    "${package_name}_"* | "${package_name}-"[0-9]* | "${package_name}-git"* | "${package_name}-v"[0-9]*)
      return 0
      ;;
  esac

  return 1
}

artifact_package_group() {
  local package_file_name="$1"

  if package_file_matches_name "$package_file_name" aria2 ||
    package_file_matches_name "$package_file_name" ariang ||
    package_file_matches_name "$package_file_name" luci-app-aria2 ||
    package_file_matches_name "$package_file_name" luci-i18n-aria2-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-aria2-zh-tw; then
    printf 'luci-app-aria2\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" frpc ||
    package_file_matches_name "$package_file_name" luci-app-frpc ||
    package_file_matches_name "$package_file_name" luci-i18n-frpc-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-frpc-zh-tw; then
    printf 'luci-app-frpc\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" frps ||
    package_file_matches_name "$package_file_name" luci-app-frps ||
    package_file_matches_name "$package_file_name" luci-i18n-frps-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-frps-zh-tw; then
    printf 'luci-app-frps\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" gecoosac ||
    package_file_matches_name "$package_file_name" luci-app-gecoosac ||
    package_file_matches_name "$package_file_name" luci-i18n-gecoosac-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-gecoosac-zh-tw; then
    printf 'luci-app-gecoosac\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" openlist2 ||
    package_file_matches_name "$package_file_name" luci-app-openlist2 ||
    package_file_matches_name "$package_file_name" luci-i18n-openlist2-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-openlist2-zh-tw; then
    printf 'luci-app-openlist2\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" luci-theme-aurora ||
    package_file_matches_name "$package_file_name" luci-app-aurora-config ||
    package_file_matches_name "$package_file_name" luci-i18n-aurora-config-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-aurora-config-zh-tw; then
    printf 'luci-theme-aurora\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" nginx ||
    package_file_matches_name "$package_file_name" nginx-full ||
    package_file_matches_name "$package_file_name" nginx-ssl; then
    printf 'nginx\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" djonehub-core ||
    package_file_matches_name "$package_file_name" luci-app-djonehub; then
    printf 'luci-app-djonehub\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" vohive-core ||
    package_file_matches_name "$package_file_name" luci-app-vohive; then
    printf 'luci-app-vohive\n'
    return 0
  fi

  return 1
}

release_package_name() {
  local package_file="$1"
  local group_name="$2"
  local package_arch
  local package_release_name
  local package_file_name
  local safe_package_name
  local sdk_prefix

  package_file_name="$(basename "$package_file")"
  safe_package_name="${package_file_name//\~/-}"
  package_arch="$(release_package_arch_suffix "$group_name")"
  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")-"

  case "$safe_package_name" in
    *.apk)
      package_release_name="${safe_package_name%.apk}-$package_arch.apk"
      ;;
    *_all.ipk)
      package_release_name="${safe_package_name%_all.ipk}_$package_arch.ipk"
      ;;
    *.ipk)
      local package_path_arch
      package_path_arch="$(basename "$(dirname "$(dirname "$package_file")")")"
      case "$safe_package_name" in
        *_"$package_path_arch".ipk)
          package_release_name="${safe_package_name%_"$package_path_arch".ipk}_$package_arch.ipk"
          ;;
        *)
          package_release_name="${safe_package_name%.ipk}_$package_arch.ipk"
          ;;
      esac
      ;;
    *)
      package_release_name="$safe_package_name"
      ;;
  esac

  case "$package_release_name" in
    main-* | 23.05-* | 24.10-* | 25.12-*)
      printf '%s\n' "$package_release_name"
      ;;
    *)
      printf '%s%s\n' "$sdk_prefix" "$package_release_name"
      ;;
  esac
}

release_package_arch_suffix() {
  local group_name="$1"

  if [ "$group_name" = luci-theme-aurora ]; then
    printf 'all\n'
    return
  fi

  printf '%s\n' "${PACKAGE_ARCH_NAME//\//-}"
}

artifact_zip_name() {
  local group_name="$1"
  local safe_arch_name="${PACKAGE_ARCH_NAME//\//-}"
  local sdk_prefix

  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

  if [ "$group_name" = luci-theme-aurora ]; then
    printf '%s-%s-all.zip\n' "$sdk_prefix" "$group_name"
    return
  fi

  printf '%s-%s-%s.zip\n' "$sdk_prefix" "$group_name" "$safe_arch_name"
}

artifact_group_should_be_skipped() {
  local group_name="$1"

  [ "$group_name" = luci-theme-aurora ] || return 1
  [ "$PACKAGE_SELECTED_ARCH" = ALL ] || return 1
  [ "$PACKAGE_ARCH_NAME" != x86-64 ]
}

generate_compile_targets() {
  COMPILE_TARGETS=()

  if selection_in luci-app-aria2 && {
    config_package_enabled aria2 ||
      config_package_enabled luci-app-aria2
  }; then
    add_compile_target package/feeds/packages/aria2/compile
  fi

  if selection_in luci-app-aria2 && {
    config_package_enabled ariang ||
      config_package_enabled ariang-nginx
  }; then
    add_compile_target package/feeds/packages/ariang/compile
  fi

  if { selection_in frp && {
    config_package_enabled frpc ||
      config_package_enabled frps
  }; } || { selection_in luci-app-frpc && {
    config_package_enabled frpc ||
      config_package_enabled luci-app-frpc
  }; } || { selection_in luci-app-frps && {
    config_package_enabled frps ||
      config_package_enabled luci-app-frps
  }; }; then
    add_compile_target package/feeds/packages/frp/compile
  fi

  if selection_in nginx && {
    config_package_enabled nginx ||
    config_package_enabled nginx-full ||
    config_package_enabled nginx-ssl
  }; then
    add_compile_target package/feeds/packages/nginx/compile
  fi

  if selection_in luci-app-openlist2 && {
    config_package_enabled openlist2 ||
      config_package_enabled luci-app-openlist2
  }; then
    add_compile_target package/openlist2/openlist2/compile
  fi

  if selection_in frp luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_compile_target package/feeds/luci/luci-app-frpc/compile
  fi

  if selection_in frp luci-app-frps && config_package_enabled luci-app-frps; then
    add_compile_target package/feeds/luci/luci-app-frps/compile
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2 && [ -d "$SDK_ROOT/package/feeds/luci/luci-app-aria2" ]; then
    add_compile_target package/feeds/luci/luci-app-aria2/compile
  fi

  if selection_in luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_compile_target package/luci-app-gecoosac/gecoosac/compile
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_compile_target package/luci-app-gecoosac/luci-app-gecoosac/compile
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_compile_target package/openlist2/luci-app-openlist2/compile
  fi

  if selection_in luci-theme-aurora && ! artifact_group_should_be_skipped luci-theme-aurora; then
    config_package_enabled luci-theme-aurora && add_compile_target package/luci-theme-aurora/compile
    config_package_enabled luci-app-aurora-config && add_compile_target package/luci-app-aurora-config/compile
  fi

  if selection_in luci-app-djonehub && core_variant_available djonehub; then
    add_compile_target package/djonehub-core/compile
  fi

  if selection_in luci-app-djonehub && config_package_enabled luci-app-djonehub; then
    add_compile_target package/luci-app-djonehub/compile
  fi

  if selection_in luci-app-vohive && core_variant_available vohive; then
    add_compile_target package/vohive-core/compile
  fi

  if selection_in luci-app-vohive && config_package_enabled luci-app-vohive; then
    add_compile_target package/luci-app-vohive/compile
  fi

  [ "${#COMPILE_TARGETS[@]}" -gt 0 ] || die "No matching package compile targets were enabled by $PACKAGE_CONFIG_FILES for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

copy_artifacts() {
  local package_bin_dir="$SDK_ROOT/bin/packages"
  local copied_count=0
  local group_dir
  local group_name
  local groups=()
  local -A group_counts=()
  local package_file
  local package_file_name
  local release_name
  local skipped_count=0
  local staging_dir="$RUNNER_TEMP/package-artifact-groups"
  local target_file
  local zip_count=0
  local zip_file

  if [ ! -d "$package_bin_dir" ]; then
    die "SDK package output directory was not created: $package_bin_dir"
  fi

  if [ -z "$(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print -quit)" ]; then
    die "No compiled .ipk or .apk files were found under $package_bin_dir"
  fi

  command -v zip >/dev/null 2>&1 || die "zip command was not found"

  rm -rf "$OUTPUT_DIR" "$staging_dir"
  mkdir -p "$OUTPUT_DIR" "$staging_dir"
  while IFS= read -r -d '' package_file; do
    package_file_name="$(basename "$package_file")"
    if ! artifact_package_allowed "$package_file_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    group_name="$(artifact_package_group "$package_file_name")" ||
      die "No artifact group was found for package file: $package_file_name"
    if artifact_group_should_be_skipped "$group_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [ -z "${group_counts[$group_name]+set}" ]; then
      group_counts[$group_name]=0
      groups+=("$group_name")
    fi

    group_dir="$staging_dir/$group_name"
    mkdir -p "$group_dir"

    release_name="$(release_package_name "$package_file" "$group_name")"
    target_file="$group_dir/$release_name"
    [ ! -e "$target_file" ] || die "Duplicate package artifact name: $target_file"
    cp -a "$package_file" "$target_file"
    group_counts[$group_name]=$((group_counts[$group_name] + 1))
    copied_count=$((copied_count + 1))
  done < <(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print0)

  [ "$copied_count" -gt 0 ] || die "No selected package files were copied from $package_bin_dir"

  for group_name in "${groups[@]}"; do
    group_dir="$staging_dir/$group_name"
    [ "${group_counts[$group_name]}" -gt 0 ] || die "No files were staged for artifact group: $group_name"

    zip_file="$OUTPUT_DIR/$(artifact_zip_name "$group_name")"
    [ ! -e "$zip_file" ] || die "Duplicate package zip artifact name: $zip_file"
    (
      cd "$group_dir"
      zip -q -r "$zip_file" .
    )
    zip_count=$((zip_count + 1))
  done

  rm -rf "$staging_dir"
  log "Packed $copied_count selected package files into $zip_count grouped zip files under $OUTPUT_DIR; skipped $skipped_count dependency files"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "PACKAGE_OUTPUT_DIR=$OUTPUT_DIR" >> "$GITHUB_ENV"
    echo "RESOLVED_SDK_URL=$RESOLVED_SDK_URL" >> "$GITHUB_ENV"
  fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

PACKAGE_SELECTION="$(normalize_package_selection "$PACKAGE_SELECTION")"
OPENWRT_SDK_VERSION="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

log "Download OpenWrt SDK"
log "Selected package group: $PACKAGE_SELECTION"
log "Selected OpenWrt SDK version: $OPENWRT_SDK_VERSION"
RESOLVED_SDK_URL="$(resolve_sdk_url)"
rm -rf "$SDK_ROOT"
mkdir -p "$RUNNER_TEMP"
download_sdk "$RESOLVED_SDK_URL"
extract_sdk "$RESOLVED_SDK_URL"
[ -x "$SDK_ROOT/scripts/feeds" ] || die "Invalid SDK archive: scripts/feeds was not found"
[ -f "$SDK_ROOT/Makefile" ] || die "Invalid SDK archive: Makefile was not found"

log "Update SDK feeds"
cd "$SDK_ROOT"
# 优化 feed 源：移除编译不需要的 telephony/video feed（部分包 Makefile 在 SDK 下不兼容，
# 会导致 feeds install -a 失败），并将 git.openwrt.org 替换为 GitHub 镜像避免 504 网关超时
if [ -f feeds.conf.default ]; then
  sed -i '/telephony/d; /video/d' feeds.conf.default
  sed -i 's#git\.openwrt\.org/openwrt/#github.com/openwrt/#g; s#git\.openwrt\.org/feed/#github.com/openwrt/#g; s#git\.openwrt\.org/project/#github.com/openwrt/#g' feeds.conf.default
fi
./scripts/feeds update -a

log "Load custom packages"
remove_builtin_packages
load_custom_packages

log "Fetch prebuilt core binaries"
fetch_prebuilt_core_binaries

log "Refresh SDK feed indexes"
./scripts/feeds update -i -a

log "Install SDK feeds"
./scripts/feeds install -a
prune_luci_translations

log "Load package config"
load_config_files
# 必须在 defconfig 之前调用：变体间的 CONFLICTS 会构成 kconfig 循环依赖，
# defconfig 之后再改 .config 会被下一次 make 自动跑的 defconfig 覆盖掉。
select_arch_specific_core_variants
disable_unavailable_core_variants
make defconfig
generate_compile_targets
generate_artifact_filters

log "Compile packages"
for compile_target in "${COMPILE_TARGETS[@]}"; do
  make -j"$(nproc)" "$compile_target" || make -j1 "$compile_target" V=s
done

log "Collect package artifacts"
copy_artifacts
