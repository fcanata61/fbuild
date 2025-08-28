#!/usr/bin/env bash
# ===============================
# FILE: lib/buildlib.sh
# Reutilizável: download (wget/curl/git), extração, patch, build, install.
# ===============================
set -euo pipefail
IFS=$'\n\t'
# ---- Config padrão ----
: "${WORK:=/tmp/work}"
: "${DESTDIR:=/tmp/dest}"
: "${OUT:=/tmp/out}"
: "${JOBS:=$(nproc || echo 2)}"
: "${PREFIX:=/usr}"

mkdir -p "$WORK" "$DESTDIR" "$OUT"

log()  { printf "\033[1;32m[OK]\033[0m %s\n"    "$*"; }
info() { printf "\033[1;34m[INFO]\033[0m %s\n"  "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n"  "$*"; }
die()  { printf "\033[1;31m[ERR]\033[0m %s\n"   "$*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Comando obrigatório ausente: $c"; done
}

ensure_deps() {
  local need=(git tar patch xz bunzip2 gzip file)
  # pelo menos um de wget/curl
  command -v wget >/dev/null || command -v curl >/dev/null || die "Precisa de wget ou curl"
  # unzip é opcional (só se .zip)
  need+=(unzip)
  for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || warn "Opcional/dep: $c não encontrado"; done
}

fetch_file() {
  # $1=url $2=saida(opcional)
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
  # $1=repo $2=dest(opcional) $3=ref(opcional)
  local repo="$1" dest="${2:-}" ref="${3:-}"
  [[ -z "$dest" ]] && dest="$WORK/$(basename -s .git "$repo")"
  if [[ -d "$dest/.git" ]]; then
    info "Atualizando repositório em $dest"; git -C "$dest" fetch --all --tags
  else
    git clone --recursive "$repo" "$dest"
  fi
  if [[ -n "$ref" ]]; then git -C "$dest" checkout "$ref"; fi
  echo "$dest"
}

extract_archive() {
  # $1=arquivo $2=destdir(opcional)
  local a="$1" dest="${2:-}"; [[ -z "$dest" ]] && dest="$WORK/src-$(date +%s)"
  mkdir -p "$dest"
  local mime; mime=$(file -b --mime-type "$a" || true)
  case "$a" in
    *.tar.gz|*.tgz)    tar -xzf "$a" -C "$dest" ;;
    *.tar.xz)          tar -xJf "$a" -C "$dest" ;;
    *.tar.bz2|*.tbz2)  tar -xjf "$a" -C "$dest" ;;
    *.tar.zst)         command -v zstd >/dev/null || die "zstd não instalado"; unzstd -c "$a" | tar -x -C "$dest" ;;
    *.zip)             command -v unzip >/dev/null || die "unzip não instalado"; unzip -q "$a" -d "$dest" ;;
    *.gz)              mkdir -p "$dest"; gunzip -c "$a" > "$dest/$(basename "${a%.gz}")" ;;
    *.xz)              mkdir -p "$dest"; unxz   -c "$a" > "$dest/$(basename "${a%.xz}")" ;;
    *.bz2)             mkdir -p "$dest"; bunzip2 -c "$a" > "$dest/$(basename "${a%.bz2}")" ;;
    *)
      case "$mime" in
        application/x-tar) tar -xf "$a" -C "$dest" ;;
        *) die "Formato não suportado: $a ($mime)" ;;
      esac ;;
  esac
  # retornar diretório raiz (se houver um único)
  local sub
  sub=$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n1)
  [[ -n "$sub" ]] && echo "$sub" || echo "$dest"
}

apply_patches() {
  # $1=srcdir, restantes: URLs ou caminhos de patches
  local src="$1"; shift || true
  [[ $# -eq 0 ]] && return 0
  pushd "$src" >/dev/null
  for p in "$@"; do
    local f="$p"
    if [[ "$p" =~ :// ]]; then f=$(fetch_file "$p"); fi
    info "Aplicando patch $(basename "$f")"
    patch -p1 < "$f"
  done
  popd >/dev/null
}

run_hook() {
  # executa função de hook se existir
  local name="$1"; shift || true
  if declare -F "$name" >/dev/null; then "$name" "$@"; fi
}

autodetect_and_build() {
  # $1=srcdir
  local src="$1"
  pushd "$src" >/dev/null
  if [[ -f configure ]]; then
    ./configure --prefix="$PREFIX"
    make -j"$JOBS"
    make DESTDIR="$DESTDIR" install
  elif [[ -f CMakeLists.txt ]]; then
    command -v cmake >/dev/null || die "cmake ausente"
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build build -j"$JOBS"
    cmake --install build --config Release --prefix "$PREFIX" --component default -- DESTDIR="$DESTDIR"
  elif [[ -f meson.build ]]; then
    command -v meson >/dev/null || die "meson ausente"
    meson setup build --prefix "$PREFIX"
    meson compile -C build -j "$JOBS"
    meson install -C build --destdir "$DESTDIR"
  else
    die "Não foi possível detectar sistema de build em $src. Forneça BUILD_STEPS."
  fi
  popd >/dev/null
}

build_with_steps() {
  # $1=srcdir, restante: comandos (cada um uma linha)
  local src="$1"; shift || true
  pushd "$src" >/dev/null
  local cmd
  for cmd in "$@"; do
    info "RUN: $cmd"
    bash -euo pipefail -c "$cmd"
  done
  popd >/dev/null
}

package_destdir() {
  # Cria pacote tar.{zst|gz} do DESTDIR
  local name="$1" version="$2" outdir="${3:-$OUT}"
  mkdir -p "$outdir"
  local pkgbase="${name}-${version}-$(uname -m)"
  local tarfile="$outdir/${pkgbase}.tar"
  (cd "$DESTDIR" && tar -cf "$tarfile" .)
  if command -v zstd >/dev/null 2>&1; then
    zstd -19 --rm "$tarfile"
    tarfile+=".zst"
  else
    gzip -9 "$tarfile"
    tarfile+=".gz"
  fi
  printf "name=%s\nversion=%s\nbuilt_at=%s\n" "$name" "$version" "$(date -u +%FT%TZ)" > "$outdir/${pkgbase}.META"
  echo "$tarfile"
}

install_binary_pkg() {
  # $1=pacote.tar.{zst|gz} $2=prefixo de instalação (raiz destino)
  local pkg="$1" root="${2:-/}"
  [[ -f "$pkg" ]] || die "Pacote não encontrado: $pkg"
  if [[ "$pkg" == *.zst ]]; then
    unzstd -c "$pkg" | tar -x -C "$root"
  else
    gunzip -c "$pkg" | tar -x -C "$root"
  fi
}
# Entrada principal para uma "receita" (sourced) usar
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
# ===============================
# FILE: recipes/hello-example.sh (exemplo de receita)
# Execute:   WORK=/tmp/w DESTDIR=/tmp/d OUT=/tmp/o ./orchestrator.sh recipes/hello-example.sh
# ===============================
# cat > recipes/hello-example.sh <<'EOF'
# NAME="hello"
# VERSION="2.12"
# SRC_URL="https://ftp.gnu.org/gnu/hello/hello-${VERSION}.tar.gz"
# PATCH_URLS=( "" ) # adicione URLs ou caminhos locais
# PREFIX="/usr" # opcional
# BUILD_STEPS=(
#   "./configure --prefix=$PREFIX"
#   "make -j$JOBS"
#   "make DESTDIR=$DESTDIR install"
# )
# pre_fetch()  { info "Preparando build do $NAME-$VERSION"; }
# post_build() { info "Build concluído"; }
# EOF

# ===============================
# FILE: orchestrator.sh
# Orquestra uma ou várias receitas e suporta instalação binária.
# ===============================
# Uso:
#   ./orchestrator.sh build <recipe1.sh> [recipe2.sh ...]
#   ./orchestrator.sh install-bin <pkg.tar.{zst|gz}> [<raiz>]
#   ./orchestrator.sh build+install <recipe.sh> [<raiz>]
# Vars relevantes: WORK DESTDIR OUT JOBS PREFIX

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    build)
      require_cmd bash
      for r in "$@"; do
        [[ -f "$r" ]] || die "Receita não encontrada: $r"
        # shellcheck disable=SC1090
        source "$r"
        # shellcheck disable=SC1091
        source "$(dirname "$0")/lib/buildlib.sh"
        build_recipe
        # limpa DESTDIR para próximo pacote
        rm -rf "$DESTDIR"; mkdir -p "$DESTDIR"
      done
      ;;
    install-bin)
      pkg="${1:-}"; root="${2:-/}"
      [[ -n "$pkg" ]] || die "Informe o pacote"
      # shellcheck disable=SC1091
      source "$(dirname "$0")/lib/buildlib.sh"
      install_binary_pkg "$pkg" "$root"
      ;;
    build+install)
      r="${1:-}"; root="${2:-/}"
      [[ -f "$r" ]] || die "Receita não encontrada"
      # shellcheck disable=SC1091
      source "$(dirname "$0")/lib/buildlib.sh"
      # shellcheck disable=SC1090
      source "$r"
      build_recipe
      pkg=$(ls -1t "$OUT"/*.tar.* | head -n1)
      info "Instalando $pkg em $root (pode requerer sudo se root != $DESTDIR)"
      install_binary_pkg "$pkg" "$root"
      ;;
    *)
      cat <<USAGE
Uso:
  WORK=/caminho DESTDIR=/caminho OUT=/caminho ./orchestrator.sh build recipes/*.sh
  ./orchestrator.sh install-bin pacote.tar.zst [/]
  ./orchestrator.sh build+install recipes/uma-receita.sh [/]
USAGE
      ;;
  esac
fi
