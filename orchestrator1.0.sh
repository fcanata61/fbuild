#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

: "${WORK:=/tmp/work}"
: "${DESTDIR:=/tmp/dest}"
: "${OUT:=/tmp/out}"
: "${JOBS:=$(nproc || echo 2)}"
: "${PREFIX:=/usr}"
: "${PATCH_LEVEL:=1}"

mkdir -p "$WORK" "$DESTDIR" "$OUT"

log()  { printf "\033[1;32m[OK]\033[0m %s\n"    "$*"; }
info() { printf "\033[1;34m[INFO]\033[0m %s\n"  "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n"  "$*"; }
die()  { printf "\033[1;31m[ERR]\033[0m %s\n"   "$*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Comando obrigatório ausente: $c"; done
}

ensure_deps() {
  local required=(git tar patch xz bunzip2 gzip file)
  local optional=(unzip zstd cmake meson)

  command -v wget >/dev/null || command -v curl >/dev/null || die "Precisa de wget ou curl"

  for c in "${required[@]}"; do command -v "$c" >/dev/null 2>&1 || die "Dependência obrigatória não encontrada: $c"; done
  for c in "${optional[@]}"; do command -v "$c" >/dev/null 2>&1 || warn "Dependência opcional não encontrada: $c"; done
}

fetch_file() {
  local url="$1" out="${2:-}"
  if [[ -z "$out" ]]; then out="$WORK/$(basename "${url%%\?*}")"; fi
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    curl -L --fail -o "$out" "$url"
  fi
  echo "$out"
}

fetch_git() {
  local repo="$1" dest="${2:-}" ref="${3:-}"
  [[ -z "$dest" ]] && dest="$WORK/$(basename -s .git "$repo")"
  if [[ -d "$dest/.git" ]]; then
    info "Atualizando repositório em $dest"
    git -C "$dest" fetch --all --tags
  else
    git clone --recursive "$repo" "$dest"
  fi
  [[ -n "$ref" ]] && git -C "$dest" checkout "$ref"
  echo "$dest"
}

extract_archive() {
  local a="$1" dest="${2:-}"; [[ -z "$dest" ]] && dest="$WORK/src-$(date +%s)"
  mkdir -p "$dest"
  local mime; mime=$(file -b --mime-type "$a" || true)
  case "$a" in
    *.tar.gz|*.tgz)    tar -xzf "$a" -C "$dest" ;;
    *.tar.xz)          tar -xJf "$a" -C "$dest" ;;
    *.tar.bz2|*.tbz2)  tar -xjf "$a" -C "$dest" ;;
    *.tar.zst)         command -v zstd >/dev/null || die "zstd não instalado"; unzstd -c "$a" | tar -x -C "$dest" ;;
    *.zip)             command -v unzip >/dev/null || die "unzip não instalado"; unzip -q "$a" -d "$dest" ;;
    *.gz)              gunzip -c "$a" > "$dest/$(basename "${a%.gz}")" ;;
    *.xz)              unxz   -c "$a" > "$dest/$(basename "${a%.xz}")" ;;
    *.bz2)             bunzip2 -c "$a" > "$dest/$(basename "${a%.bz2}")" ;;
    *)
      case "$mime" in
        application/x-tar) tar -xf "$a" -C "$dest" ;;
        *) die "Formato não suportado: $a ($mime)" ;;
      esac ;;
  esac

  local subdirs
  subdirs=$(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if [[ "$subdirs" -eq 1 ]]; then
    find "$dest" -mindepth 1 -maxdepth 1 -type d
  else
    echo "$dest"
  fi
}

apply_patches() {
  local src="$1"; shift || true
  [[ $# -eq 0 ]] && return 0
  pushd "$src" >/dev/null
  for p in "$@"; do
    local f="$p"
    [[ "$p" =~ :// ]] && f=$(fetch_file "$p")
    info "Aplicando patch $(basename "$f")"
    patch -p"$PATCH_LEVEL" < "$f"
  done
  popd >/dev/null
}

run_hook() {
  local name="$1"; shift || true
  if declare -F "$name" >/dev/null; then "$name" "$@"; fi
}

autodetect_and_build() {
  local src="$1"
  pushd "$src" >/dev/null
  if [[ -f configure ]]; then
    ./configure --prefix="$PREFIX"
    make -j"$JOBS"
    make DESTDIR="$DESTDIR" install
  elif [[ -f CMakeLists.txt ]]; then
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build build -j"$JOBS"
    cmake --install build --config Release --prefix "$PREFIX" --component default -- DESTDIR="$DESTDIR"
  elif [[ -f meson.build ]]; then
    meson setup build --prefix "$PREFIX"
    meson compile -C build -j "$JOBS"
    meson install -C build --destdir "$DESTDIR"
  else
    die "Não foi possível detectar sistema de build em $src. Forneça BUILD_STEPS."
  fi
  popd >/dev/null
}

build_with_steps() {
  local src="$1"; shift || true
  pushd "$src" >/dev/null
  bash -euo pipefail -c "$(printf '%s\n' "$@")"
  popd >/dev/null
}

package_destdir() {
  local name="$1" version="$2" outdir="${3:-$OUT}"
  mkdir -p "$outdir"
  local pkgbase="${name}-${version}-$(uname -m)"
  local tarfile="$outdir/${pkgbase}.tar"

  (cd "$DESTDIR" && tar -cf "$tarfile" .)

  printf "name=%s\nversion=%s\nbuilt_at=%s\n" \
    "$name" "$version" "$(date -u +%FT%TZ)" > "$DESTDIR/.META"
  (cd "$DESTDIR" && tar -rf "$tarfile" .META)
  rm -f "$DESTDIR/.META"

  if command -v zstd >/dev/null 2>&1; then
    zstd -19 --rm "$tarfile"
    tarfile+=".zst"
  else
    gzip -9 "$tarfile"
    tarfile+=".gz"
  fi
  echo "$tarfile"
}

install_binary_pkg() {
  local pkg="$1" root="${2:-/}"
  [[ -f "$pkg" ]] || die "Pacote não encontrado: $pkg"
  if [[ "$pkg" == *.zst ]]; then
    unzstd -c "$pkg" | tar -x -C "$root"
  else
    gunzip -c "$pkg" | tar -x -C "$root"
  fi
}

build_recipe() {
  ensure_deps
  [[ -z "${NAME:-}" ]] && die "Receita: defina NAME"
  [[ -z "${VERSION:-}" ]] && die "Receita: defina VERSION"
  [[ -z "${SRC_URL:-}" ]] && [[ -z "${GIT_URL:-}" ]] && die "Receita: defina SRC_URL ou GIT_URL"

  run_hook pre_fetch

  local srcdir
  if [[ -n "${GIT_URL:-}" ]]; then
    srcdir=$(fetch_git "$GIT_URL" "${GIT_DIR:-}" "${GIT_REF:-}")
  else
    local f; f=$(fetch_file "$SRC_URL")
    srcdir=$(extract_archive "$f")
  fi

  run_hook post_extract "$srcdir"

  if [[ -n "${PATCH_URLS[*]:-}" ]]; then
    apply_patches "$srcdir" "${PATCH_URLS[@]}"
  fi

  run_hook pre_build "$srcdir"

  if [[ -n "${BUILD_STEPS[*]:-}" ]]; then
    build_with_steps "$srcdir" "${BUILD_STEPS[@]}"
  else
    autodetect_and_build "$srcdir"
  fi

  run_hook post_build "$srcdir"

  local pkg; pkg=$(package_destdir "$NAME" "$VERSION" "$OUT")
  info "Pacote criado: $pkg"
}
