#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Geomdb Hub — Deployment Manager
#  Jalankan: bash deploy.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Variant installer (diisi CI saat build, kosong = generik) ───────────────
# Contoh: GEOMDB_INSTALLER_VARIANT="metadata"  → NEXT_PUBLIC_BASE_PATH sudah
# terbaked di image; installer tidak perlu tanya varian ke user.
GEOMDB_INSTALLER_VARIANT=""

# ─── Warna ────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m'
DIM='\033[2m' NC='\033[0m'

LOG_FILE="deploy.log"

log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
ok()   { log "${G}✓${NC} $*"; }
err()  { log "${R}✗${NC} $*"; }
warn() { log "${Y}⚠${NC} $*"; }
info() { log "${C}→${NC} $*"; }

# ─── WSL: fix git dubious ownership ──────────────────────────────────────────
_fix_safe_dir() {
  local dir
  dir="$(pwd)"
  if git rev-parse --git-dir &>/dev/null; then return; fi
  git config --global --add safe.directory "$dir" 2>/dev/null && \
    warn "safe.directory ditambahkan untuk $dir"
}
_fix_safe_dir

# ─── Deteksi branch & environment ─────────────────────────────────────────────
get_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"; }
get_env() {
  case "$(get_branch)" in
    production)  echo "production" ;;
    staging)     echo "staging" ;;
    *)           echo "development" ;;
  esac
}

load_env() {
  local env_file=".env.$(get_env)"
  if [[ -f "$env_file" ]]; then
    set -a; source "$env_file"; set +a
    ok "Loaded $env_file"
  elif [[ -f ".env" ]]; then
    set -a; source ".env"; set +a
    warn "Tidak ada $env_file — pakai .env"
  else
    err "Tidak ada file env! Jalankan menu 9 (Generate .env) untuk membuat konfigurasi."
    exit 1
  fi
  # MinIO/S3 hanya menerima bucket name lowercase
  MINIO_BUCKET="${MINIO_BUCKET,,}"
}

# Load env tanpa output — untuk tampilan menu saja
_load_env_quiet() {
  local ef=".env.$(get_env)"
  [[ -f "$ef" ]] || ef=".env"
  [[ -f "$ef" ]] || return 0
  set -a; source "$ef"; set +a
  MINIO_BUCKET="${MINIO_BUCKET,,}"
}

# ─── Build helper dengan fallback ────────────────────────────────────────────
# Coba build dengan --pull (image terbaru dari registry).
# Jika gagal (misal: timeout ke Docker Hub), coba tanpa --pull (pakai cache lokal).
# Jika tetap gagal, tampilkan pesan jelas dan return 1.
_build_compose() {
  local label="$1"; shift
  # Attempt 1: Docker Hub + pull terbaru
  info "Build ${label} (Docker Hub)..."
  if docker compose build --pull "$@"; then
    ok "Build ${label} selesai."
    return 0
  fi
  warn "Build ${label} gagal — kemungkinan jaringan ke Docker Hub bermasalah."

  # Attempt 2: pakai layer cache lokal (tanpa pull)
  info "Mencoba build ulang tanpa --pull (cache lokal)..."
  if docker compose build "$@"; then
    warn "Build ${label} selesai via cache lokal. Image mungkin bukan versi terbaru."
    return 0
  fi
  warn "Cache lokal tidak tersedia."

  # Attempt 3: AWS ECR Public mirror
  info "Mencoba build via mirror AWS ECR Public (public.ecr.aws/docker/library)..."
  if docker compose build --pull \
      --build-arg NODE_REGISTRY=public.ecr.aws/docker/library "$@"; then
    warn "Build ${label} selesai via AWS ECR Public mirror."
    return 0
  fi

  err "Semua attempt build ${label} gagal. Periksa:"
  err "  • Koneksi ke Docker Hub  →  curl -I https://registry-1.docker.io"
  err "  • Koneksi ke AWS ECR     →  curl -I https://public.ecr.aws"
  err "  • Rate limit Docker Hub  →  docker login"
  err "  • Pull manual            →  docker pull node:22-slim"
  return 1
}

# ─── Auto-detect subnet Docker yang belum dipakai ────────────────────────────
# Preferensikan 172.20–39/24. Hanya lewati second-octet yang sudah punya /16
# (Docker daemon menolak /24 di dalam /16 yang sama). Fallback ke 192.168.200+.
_find_free_subnet() {
  local used
  used=$(docker network ls -q 2>/dev/null \
    | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | sort -u)

  local i candidate
  # Coba 172.20–39; skip second-octet yang sudah punya /16 di range itu
  for i in $(seq 20 39); do
    candidate="172.${i}.0.0/24"
    echo "$used" | grep -qE "^172\.${i}\.[0-9]+\.[0-9]+/16$" && continue
    echo "$used" | grep -qF "$candidate"                       && continue
    echo "$candidate"; return 0
  done

  # Fallback: 192.168.200–220
  for i in $(seq 200 220); do
    candidate="192.168.${i}.0/24"
    echo "$used" | grep -qF "$candidate" || { echo "$candidate"; return 0; }
  done

  echo "192.168.200.0/24"  # last resort
}

# ─── Deteksi mode installer (tanpa source code) ──────────────────────────────
# Jika tidak ada Dockerfile atau src/, kita dalam "installer mode"
_is_installer_mode() {
  [[ ! -f "Dockerfile" && ! -d "src" ]]
}

# ─── Pilih metode instalasi image app/migrate/ext-serv ───────────────────────
# Set variabel global INSTALL_METHOD: "local" | "registry-github" | "tarball"
# Set variabel global REGISTRY_USER, REGISTRY_TOKEN (untuk mode registry)
_pick_install_method() {
  while true; do
    echo ""
    if _is_installer_mode; then
      # Installer mode: tidak ada source, hanya registry atau tarball
      echo -e "  ${W}┌─ Cara mendapatkan image aplikasi ──────────────────────────┐${NC}"
      echo "  │  1) Registry GitHub  — pull dari ghcr.io                   │"
      echo "  │  2) File installer   — load dari geomdb-hub-*.tar.gz        │"
      echo "  └────────────────────────────────────────────────────────────┘"
      echo -e "  ${DIM}Pilih 2 jika mendapat file installer offline dari maintainer.${NC}"
      echo ""
      read -rp "  Pilih cara instalasi [1]: " _im
      case "${_im:-1}" in
        2) INSTALL_METHOD="tarball"; break ;;
        *) INSTALL_METHOD="registry-github"
           echo ""
           echo -e "  ${DIM}Image publik → kosongkan saja (pull anonim). Isi PAT (read:packages) hanya bila image privat.${NC}"
           read -rp "  GitHub username (kosongkan jika publik): " REGISTRY_USER
           read -rsp "  Personal Access Token (kosongkan jika publik): " REGISTRY_TOKEN; echo
           break ;;
      esac
    else
      # Dev mode: ada source code, semua opsi tersedia
      echo -e "  ${W}┌─ Cara mendapatkan image aplikasi ──────────────────────────┐${NC}"
      echo "  │  1) Build lokal      — dari source code (5-15 menit)       │"
      echo "  │  2) Registry GitHub  — pull dari ghcr.io                   │"
      echo "  │  3) File installer   — load dari geomdb-hub-*.tar.gz        │"
      echo "  └────────────────────────────────────────────────────────────┘"
      echo -e "  ${DIM}Pilih 3 jika mendapat file installer offline dari maintainer.${NC}"
      echo ""
      read -rp "  Pilih cara instalasi [1]: " _im
    fi
    case "${_im:-1}" in
      2)
        INSTALL_METHOD="registry-github"
        echo ""
        echo -e "  ${DIM}Image publik → kosongkan saja (pull anonim). Isi PAT (read:packages) hanya bila image privat.${NC}"
        read -rp "  GitHub username (kosongkan jika publik): " REGISTRY_USER
        read -rsp "  Personal Access Token (kosongkan jika publik): " REGISTRY_TOKEN; echo
        break
        ;;
      3) INSTALL_METHOD="tarball"; break ;;
      *) INSTALL_METHOD="local"; break ;;
    esac
  done
  ok "Metode: ${INSTALL_METHOD}"
}

# Pastikan image infra tersedia di cache lokal (untuk mode tarball/offline).
# Urutan: cache lokal → geomdb-infra-*.tar.gz → instruksi manual.
_ensure_infra_images() {
  local infra_images=(
    "postgis/postgis:16-3.4-alpine"
    "minio/minio:latest"
    "redis:7-alpine"
    "geopython/pycsw:2.6.1"
  )

  local missing=()
  for img in "${infra_images[@]}"; do
    docker image inspect "$img" &>/dev/null || missing+=("$img")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Semua image infra tersedia di cache lokal."
    return 0
  fi

  warn "Image infra berikut tidak ditemukan di cache lokal:"
  for img in "${missing[@]}"; do
    echo "    • $img"
  done
  echo ""

  # Cari bundle infra: nama lama (geomdb-infra-*.tar.gz) ATAU nama rilis baru (geomdb-hub-*-infra.tar.gz)
  local infra_tars=()
  mapfile -t infra_tars < <(ls geomdb-infra-*.tar.gz geomdb-hub-*-infra.tar.gz 2>/dev/null || true)

  if [[ ${#infra_tars[@]} -gt 0 ]]; then
    local infra_tar="${infra_tars[0]}"
    if [[ ${#infra_tars[@]} -gt 1 ]]; then
      echo -e "  ${W}File installer infra ditemukan:${NC}"
      for i in "${!infra_tars[@]}"; do
        echo "  $((i+1))) ${infra_tars[$i]}"
      done
      read -rp "  Pilih file [1]: " _ti
      local _idx=$(( ${_ti:-1} - 1 ))
      infra_tar="${infra_tars[$_idx]}"
    fi
    info "Memuat image infra dari ${infra_tar} (bisa beberapa menit)..."
    docker load < "$infra_tar"
    ok "Image infra berhasil dimuat."
    return 0
  fi

  # Tidak ada cache dan tidak ada tarball infra — berikan instruksi
  echo -e "  ${R}Server baru terdeteksi — image infra belum ada di cache Docker.${NC}"
  echo ""
  echo -e "  ${W}Opsi A — Siapkan geomdb-infra-*.tar.gz dari mesin lain (direkomendasikan):${NC}"
  echo "    docker pull postgis/postgis:16-3.4-alpine minio/minio:latest \\"
  echo "               redis:7-alpine geopython/pycsw:2.6.1"
  echo "    docker save postgis/postgis:16-3.4-alpine minio/minio:latest \\"
  echo "                redis:7-alpine geopython/pycsw:2.6.1 \\"
  echo "      | gzip > geomdb-infra-v1.tar.gz"
  echo "    # Salin geomdb-infra-v1.tar.gz ke folder ini, lalu jalankan deploy lagi."
  echo ""
  echo -e "  ${W}Opsi B — Pull langsung di server ini (butuh internet sementara):${NC}"
  echo "    docker compose pull postgres redis minio pycsw"
  echo ""
  read -rp "  Pull image infra sekarang via internet? [Y/n]: " _pull_infra
  if [[ ! "${_pull_infra,,}" =~ ^n ]]; then
    info "Menarik image infra dari internet (bisa beberapa menit)..."
    if docker compose pull postgres redis minio pycsw; then
      ok "Image infra berhasil di-pull."
      return 0
    fi
    err "Gagal pull image infra. Periksa koneksi internet, atau siapkan geomdb-infra-*.tar.gz (Opsi A)."
    return 1
  fi
  warn "Dilewati. Siapkan geomdb-infra-*.tar.gz (Opsi A) lalu jalankan deploy lagi."
  return 1
}

# Setelah docker load tarball: retag image lokal (geomdb-app:latest dll.) ke nama
# registry yang tersimpan di .env. Tanpa ini docker compose akan terus pakai cache
# registry lama dan container tidak direcreate meski image baru sudah dimuat.
_retag_tarball_to_env() {
  local ef=".env.$(get_env)"; [[ -f "$ef" ]] || ef=".env"
  [[ -f "$ef" ]] || return 0
  local pairs=(
    "GEOMDB_APP_IMAGE=geomdb-app:latest"
    "GEOMDB_MIGRATE_IMAGE=geomdb-migrate:latest"
    "GEOMDB_EXT_SERV_IMAGE=geomdb-ext-serv:latest"
  )
  for pair in "${pairs[@]}"; do
    local key="${pair%%=*}" src="${pair#*=}"
    local dst; dst=$(grep -E "^${key}=" "$ef" 2>/dev/null | head -1 | cut -d= -f2-)
    [[ -z "$dst" || "$dst" == geomdb-* ]] && continue
    dst="${dst%%:*}:latest"
    docker tag "$src" "$dst" 2>/dev/null && info "Retag ${src} → ${dst}" || true
  done
}

# Load/pull image dari CI sesuai INSTALL_METHOD (dipanggil sebelum start container)
_apply_install_method() {
  case "${INSTALL_METHOD:-local}" in
    registry-github)
      # Namespace PUBLIK → instansi pull anonim tanpa token. Override via
      # GEOMDB_APP_IMAGE/GEOMDB_*_IMAGE bila ingin pakai namespace privat.
      local _reg_base="ghcr.io/harihk1/geomdb-hub-installer"

      # Kalau GEOPORTAL_NETWORK diset (server punya geoportal), pakai app-geoportal
      # yang sudah baked-in NEXT_PUBLIC_BASE_PATH=/geomdb-hub
      local _default_app_img
      if [[ -n "${GEOMDB_INSTALLER_VARIANT:-}" ]]; then
        _default_app_img="${_reg_base}/app-${GEOMDB_INSTALLER_VARIANT}"
        info "Varian hardcoded: ${GEOMDB_INSTALLER_VARIANT} → pakai image app-${GEOMDB_INSTALLER_VARIANT}"
      elif [[ -n "${GEOPORTAL_NETWORK:-}" ]]; then
        _default_app_img="${_reg_base}/app-geoportal"
        info "Terdeteksi geoportal (GEOPORTAL_NETWORK=${GEOPORTAL_NETWORK}) → pakai image app-geoportal"
      else
        _default_app_img="${_reg_base}/app-standalone"
      fi
      export GEOMDB_APP_IMAGE="${GEOMDB_APP_IMAGE:-${_default_app_img}}"
      export GEOMDB_MIGRATE_IMAGE="${GEOMDB_MIGRATE_IMAGE:-${_reg_base}/migrate}"
      export GEOMDB_EXT_SERV_IMAGE="${GEOMDB_EXT_SERV_IMAGE:-${_reg_base}/ext-serv}"

      local _registry_host
      _registry_host="$(echo "${GEOMDB_APP_IMAGE}" | cut -d/ -f1)"
      # Login HANYA bila token diisi (image privat). Image publik → pull anonim.
      if [[ -n "${REGISTRY_TOKEN:-}" ]]; then
        info "Login ke ${_registry_host}..."
        echo "${REGISTRY_TOKEN}" | docker login "${_registry_host}" \
          -u "${REGISTRY_USER}" --password-stdin \
          || { err "Login registry gagal. Cek username dan token."; return 1; }
      else
        info "Tanpa token → pull anonim (image publik) dari ${_registry_host}..."
      fi
      info "Pull image aplikasi dari ${_registry_host}..."
      docker compose pull app migrate ext-serv
      ok "Image berhasil di-pull dari registry."
      [[ -n "${REGISTRY_TOKEN:-}" ]] && docker logout "${_registry_host}" 2>/dev/null || true
      ;;
    tarball)
      local tarfiles=()
      # Cocokkan Docker image bundle: *-standalone.tar.gz / *-geoportal.tar.gz / *-<kustom>.tar.gz
      # Jangan tangkap *-installer.tar.gz (installer package) atau *-infra.tar.gz
      mapfile -t tarfiles < <(ls geomdb-hub-*.tar.gz 2>/dev/null \
        | grep -v '\-installer\.tar\.gz$' | grep -v '\-infra\.tar\.gz$' | sort -u || true)
      if [[ ${#tarfiles[@]} -eq 0 ]]; then
        # Cek apakah ada *-installer.tar.gz yang mengandung inner bundle
        local installer_tars=()
        mapfile -t installer_tars < <(ls geomdb-hub-*-standalone-installer.tar.gz geomdb-hub-*-geoportal-installer.tar.gz 2>/dev/null || true)
        if [[ ${#installer_tars[@]} -gt 0 ]]; then
          local inst_tar="${installer_tars[0]}"
          info "Ditemukan installer package: ${inst_tar} — mengekstrak Docker image bundle..."
          local _inner
          _inner=$(tar -tzf "$inst_tar" 2>/dev/null | grep -E 'geomdb-hub-.*-(standalone|geoportal)\.tar\.gz$' | head -1)
          if [[ -z "$_inner" ]]; then
            err "Tidak dapat menemukan Docker image bundle di dalam ${inst_tar}."
          else
            tar -xzf "$inst_tar" --strip-components=1 "$_inner" 2>/dev/null \
              || tar -xzf "$inst_tar" "$_inner" 2>/dev/null
            local _extracted
            _extracted=$(basename "$_inner")
            if [[ -f "$_extracted" ]]; then
              ok "Bundle diekstrak: ${_extracted}"
              mapfile -t tarfiles < <(ls geomdb-hub-*-standalone.tar.gz geomdb-hub-*-geoportal.tar.gz 2>/dev/null || true)
            else
              err "Gagal mengekstrak ${_inner} dari ${inst_tar}."
            fi
          fi
        fi
      fi
      if [[ ${#tarfiles[@]} -eq 0 ]]; then
        warn "Tidak ada file Docker image bundle (geomdb-hub-*-standalone.tar.gz atau geomdb-hub-*-geoportal.tar.gz) di folder ini."
        echo ""
        # Default: repo PUBLIK geomdb-hub-installer → unduh anonim tanpa token.
        # Override ke repo lain (mis. privat) via env GEOMDB_GH_REPO bila perlu.
        local _ghrepo="${GEOMDB_GH_REPO:-hariHK1/geomdb-hub-installer}"
        echo -e "  ${W}Unduh otomatis dari GitHub Releases?${NC}"
        echo -e "  ${DIM}https://github.com/${_ghrepo}/releases${NC}"
        read -rp "  Unduh sekarang? [Y/n]: " _dl
        if [[ "${_dl,,}" =~ ^n ]]; then
          err "Dibatalkan. Salin geomdb-hub-*.tar.gz ke folder ini, atau unduh manual dari Releases."
          return 1
        fi
        # Rilis di repo publik → token TIDAK diperlukan. Hanya isi PAT bila Anda
        # menunjuk repo privat via GEOMDB_GH_REPO (butuh scope repo / Contents:Read).
        echo -e "  ${DIM}Rilis publik → biarkan PAT kosong. Isi hanya bila repo rilis privat.${NC}"
        local _ghtoken _auth=()
        read -rsp "  GitHub PAT (kosongkan untuk rilis publik): " _ghtoken; echo
        [[ -n "$_ghtoken" ]] && _auth=(-H "Authorization: token ${_ghtoken}")

        # Deteksi tag rilis terbaru via GitHub API (terautentikasi bila token diisi)
        local _tag _httpcode
        _tag=$(curl -fsSL "${_auth[@]}" "https://api.github.com/repos/${_ghrepo}/releases/latest" 2>/dev/null \
                 | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        if [[ -z "$_tag" ]]; then
          # Tampilkan kode HTTP agar jelas penyebabnya (401 token salah / 404 tak ada akses)
          _httpcode=$(curl -s -o /dev/null -w "%{http_code}" "${_auth[@]}" "https://api.github.com/repos/${_ghrepo}/releases/latest" 2>/dev/null)
          warn "Gagal deteksi versi terbaru (GitHub HTTP ${_httpcode:-?})."
          case "$_httpcode" in
            401) echo -e "  ${DIM}→ Token salah/kadaluarsa.${NC}" ;;
            404) echo -e "  ${DIM}→ Token tak punya akses ke repo privat (scope 'repo' kurang).${NC}" ;;
          esac
          read -rp "  Masukkan tag rilis manual (mis. v0.1.3): " _tag
        else
          read -rp "  Versi terbaru: ${_tag} — Enter untuk pakai, atau ketik tag lain: " _tsel
          _tag="${_tsel:-$_tag}"
        fi
        [[ -z "$_tag" ]] && { err "Tag rilis kosong."; return 1; }
        # Varian: geoportal / standalone / sub-direktori kustom
        local _variant
        if [[ -n "${GEOMDB_INSTALLER_VARIANT:-}" ]]; then
          _variant="${GEOMDB_INSTALLER_VARIANT}"
          info "Varian hardcoded: ${_variant}"
        else
          echo -e "  ${W}Pilih varian instalasi:${NC}"
          echo "  1) geoportal  — diakses di sub-path /geomdb-hub"
          echo "  2) standalone — diakses di root / (server dedicated)"
          echo "  3) metadata   — diakses di sub-path /metadata"
          while true; do
            read -rp "  Pilih [2]: " _v
            case "${_v:-2}" in
              1) _variant="geoportal"; break ;;
              2) _variant="standalone"; break ;;
              3) _variant="metadata"; break ;;
              *) echo -e "  ${R}✗${NC} Masukkan 1, 2, atau 3." ;;
            esac
          done
        fi
        local _asset="geomdb-hub-${_tag}-${_variant}-installer.tar.gz"
        info "Mengunduh ${_asset} (bisa beberapa menit)..."
        if [[ -n "$_ghtoken" ]]; then
          # Privat: resolve asset id via API, lalu unduh via endpoint assets (octet-stream)
          local _rel _aid
          _rel=$(curl -fsSL -H "Authorization: token ${_ghtoken}" \
                   "https://api.github.com/repos/${_ghrepo}/releases/tags/${_tag}" 2>/dev/null)
          [[ -z "$_rel" ]] && { err "Gagal akses rilis ${_tag}. Cek token (scope repo) & tag."; return 1; }
          if command -v python3 &>/dev/null; then
            _aid=$(printf '%s' "$_rel" | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((a['id'] for a in d.get('assets',[]) if a['name']=='${_asset}'),''))" 2>/dev/null)
          else
            _aid=$(printf '%s' "$_rel" | grep -B5 "\"name\": \"${_asset}\"" | grep -oE '"id": [0-9]+' | head -1 | grep -oE '[0-9]+')
          fi
          [[ -z "$_aid" ]] && { err "Asset ${_asset} tidak ditemukan di rilis ${_tag} (cek varian)."; return 1; }
          curl -fL -H "Authorization: token ${_ghtoken}" -H "Accept: application/octet-stream" \
            -o "$_asset" "https://api.github.com/repos/${_ghrepo}/releases/assets/${_aid}" \
            || { err "Gagal mengunduh asset (cek token/jaringan)."; rm -f "$_asset"; return 1; }
        else
          # Publik: unduh langsung
          local _url="https://github.com/${_ghrepo}/releases/download/${_tag}/${_asset}"
          if command -v curl &>/dev/null; then
            curl -fL --retry 3 -o "$_asset" "$_url" || { err "Gagal mengunduh dari ${_url}."; rm -f "$_asset"; return 1; }
          elif command -v wget &>/dev/null; then
            wget -O "$_asset" "$_url" || { err "Gagal mengunduh dari ${_url}."; rm -f "$_asset"; return 1; }
          else
            err "curl/wget tidak tersedia untuk mengunduh."; return 1
          fi
        fi
        gzip -t "$_asset" 2>/dev/null || { err "File terunduh tidak valid (kemungkinan tag/varian salah)."; rm -f "$_asset"; return 1; }
        info "Mengekstrak image bundle dari installer..."
        tar -xzf "$_asset"
        local _img
        _img=$(ls "geomdb-hub-${_tag}/geomdb-hub-${_tag}-${_variant}.tar.gz" 2>/dev/null | head -1)
        if [[ -z "$_img" ]]; then
          err "Image bundle tidak ditemukan di dalam ${_asset}."; return 1
        fi
        cp "$_img" .
        rm -f "$_asset"; rm -rf "geomdb-hub-${_tag}"
        ok "Image bundle siap: $(basename "$_img")"
        mapfile -t tarfiles < <(ls geomdb-hub-*-standalone.tar.gz geomdb-hub-*-geoportal.tar.gz "geomdb-hub-${_tag}-${_variant}.tar.gz" 2>/dev/null | sort -u || true)
        [[ ${#tarfiles[@]} -eq 0 ]] && { err "Image bundle tidak ditemukan setelah unduh."; return 1; }
      fi
      local tarfile="${tarfiles[0]}"
      if [[ ${#tarfiles[@]} -gt 1 ]]; then
        echo ""
        echo -e "  ${W}File installer ditemukan:${NC}"
        for i in "${!tarfiles[@]}"; do
          echo "  $((i+1))) ${tarfiles[$i]}"
        done
        read -rp "  Pilih file [1]: " _ti
        local _idx=$(( ${_ti:-1} - 1 ))
        tarfile="${tarfiles[$_idx]}"
      fi
      info "Memuat image dari ${tarfile} (bisa beberapa menit)..."
      docker load < "$tarfile"
      ok "Image berhasil dimuat dari ${tarfile}."
      _retag_tarball_to_env
      ;;
  esac
}

# ─── Header ───────────────────────────────────────────────────────────────────
show_header() {
  local branch env
  branch=$(get_branch)
  env=$(get_env)
  local color=$G
  [[ "$env" == "staging" ]]    && color=$Y
  [[ "$env" == "production" ]] && color=$R

  clear
  echo -e "${W}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        Geomdb Hub — Deploy Manager      ║"
  echo "  ╠══════════════════════════════════════════════╣"
  printf "  ║  Branch  : ${color}%-34s${W}║\n" "$branch"
  printf "  ║  Env     : ${color}%-34s${W}║\n" "$env"
  printf "  ║  Host    : %-34s║\n" "$(hostname)"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─── Konfirmasi production ────────────────────────────────────────────────────
confirm_production() {
  local action="${1:-operasi ini}"
  if [[ "$(get_env)" == "production" ]]; then
    echo -e "${R}⚠  PRODUCTION ENVIRONMENT ⚠${NC}"
    echo -e "${Y}   Anda akan menjalankan: ${W}$action${NC}"
    read -rp "   Ketik 'PRODUCTION' untuk konfirmasi: " confirm
    [[ "$confirm" == "PRODUCTION" ]] || { warn "Dibatalkan."; return 1; }
  fi
}

# ─── 1. Switch branch ─────────────────────────────────────────────────────────
fn_switch_branch() {
  echo -e "\n${W}  Switch Branch${NC}"
  echo "  ─────────────────────────────"
  echo "  1) development  (dev lokal)"
  echo "  2) staging      (pre-production)"
  echo "  3) production   (live server)"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih: " choice

  local target
  case $choice in
    1) target="development" ;;
    2) target="staging" ;;
    3) target="production"
       confirm_production "switch ke branch production" || return ;;
    0) return ;;
    *) warn "Pilihan tidak valid."; return ;;
  esac

  if [[ "$(get_branch)" == "$target" ]]; then
    warn "Sudah di branch $target."
    return
  fi

  # Stash jika ada perubahan
  if ! git diff --quiet || ! git diff --cached --quiet; then
    warn "Ada perubahan lokal — melakukan git stash..."
    git stash push -m "deploy-manager auto stash $(date '+%Y%m%d-%H%M%S')"
  fi

  git checkout "$target"
  ok "Switched ke branch: $target"
}

# ─── 2. Pull ──────────────────────────────────────────────────────────────────
fn_pull() {
  local branch
  branch=$(get_branch)
  echo -e "\n${W}  Git Pull${NC} — branch: ${C}$branch${NC}"
  echo "  ─────────────────────────────"

  if ! git diff --quiet || ! git diff --cached --quiet; then
    warn "Ada perubahan lokal — melakukan git stash..."
    git stash push -m "deploy-manager pre-pull $(date '+%Y%m%d-%H%M%S')"
  fi

  info "git pull origin $branch"
  git pull origin "$branch" && ok "Pull selesai." || err "Pull gagal!"
}

# ─── 3. Deploy ────────────────────────────────────────────────────────────────
fn_deploy() {
  local env
  env=$(get_env)

  echo -e "\n${W}  Deploy${NC} — env: ${C}$env${NC}"
  echo "  ─────────────────────────────"
  confirm_production "deploy ke production" || return
  load_env

  # Pilih cara instalasi image aplikasi
  _pick_install_method

  # 1. Infra (postgres, redis, minio, pycsw)
  # Mode tarball (offline): skip pull — gunakan image yang sudah ada di cache lokal.
  # Jika belum pernah di-pull, jalankan sekali: docker compose pull postgres redis minio pycsw
  if [[ "${INSTALL_METHOD:-local}" != "tarball" ]]; then
    info "Pull image infra terbaru..."
    docker compose pull postgres redis minio pycsw
  else
    info "Mode offline (tarball) — memeriksa cache image infra..."
    _ensure_infra_images || return 1
  fi
  # ext_serv-main/.env opsional (konfigurasi WA extra), tapi wajib ada sebagai file
  # agar kompatibel dengan Compose versi lama yang tidak support {path,required} syntax
  mkdir -p ext_serv-main && touch ext_serv-main/.env

  docker compose up -d --remove-orphans postgres redis minio pycsw
  ok "Infra containers running."

  # 2. Siapkan image app/migrate/ext-serv
  if [[ "${INSTALL_METHOD:-local}" == "local" ]]; then
    _build_compose "ext-serv + migrator" ext-serv migrate || return 1
  else
    _apply_install_method || return 1
  fi

  # 3. Tunggu postgres healthy
  info "Menunggu postgres healthy..."
  local tries=0
  until docker compose exec -T postgres pg_isready -U geomdb -d geomdb_hub &>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -ge 30 ]] && { err "Postgres tidak ready setelah 60 detik."; return 1; }
    sleep 2
  done
  ok "Postgres ready."

  # 4. Migrasi DB
  info "Jalankan migrasi DB..."
  docker compose run --rm migrate && ok "Migrasi selesai."

  # 5. Auto-seed jika database masih kosong
  info "Memeriksa apakah database perlu di-seed..."
  local user_count
  user_count=$(docker compose exec -T postgres psql -U geomdb -d geomdb_hub -tAq \
    -c 'SELECT COUNT(*) FROM "User";' 2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "$user_count" == "0" ]]; then
    info "Database kosong — menjalankan seed data awal..."
    docker compose run --rm migrate npx tsx prisma/seed.ts && ok "Seed selesai."
  else
    info "Database sudah berisi data ($user_count user) — seed awal dilewati."
    # Saat upgrade: perbarui HANYA dokumentasi (panduan + FAQ) agar konten terbaru
    # ikut terpasang. Aman — tidak menyentuh user/pengaturan/standar/metadata.
    info "Memperbarui dokumentasi (panduan + FAQ)..."
    docker compose run --rm migrate npx tsx prisma/seed-docs-only.ts \
      && ok "Dokumentasi diperbarui." || warn "Update dokumentasi dilewati."
  fi

  # 6. Start + tunggu ext-serv healthy
  info "Menjalankan ext-serv container..."
  docker compose up -d --no-deps ext-serv
  ok "ext-serv container started."
  info "Menunggu ext-serv healthy..."
  local ext_tries=0
  until docker compose exec -T ext-serv node -e "fetch('http://localhost:${PORT_EXT_SERV:-3007}/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" &>/dev/null; do
    ext_tries=$((ext_tries + 1))
    [[ $ext_tries -ge 20 ]] && { warn "ext-serv belum healthy setelah 40 detik — lanjutkan deploy."; break; }
    sleep 2
  done
  ok "ext-serv healthy."

  # 7. Build app (hanya jika build lokal)
  if [[ "${INSTALL_METHOD:-local}" == "local" ]]; then
    _build_compose "app" app || return 1
  fi

  # 8. Rolling restart app
  info "Menjalankan app container..."
  docker compose up -d --no-deps app
  ok "App container started."

  # 9. SSL cert + Nginx
  if [[ "${USE_NGINX:-true}" == "false" ]]; then
    warn "Nginx dinonaktifkan (USE_NGINX=false) — skip Docker Nginx dan Certbot."
    info "App dapat diakses langsung di port ${PORT_APP:-3000}."
  elif [[ "${USE_EXTERNAL_NGINX:-false}" == "true" ]]; then
    warn "Nginx eksternal — skip Docker Nginx dan Certbot."
    info "Pastikan Nginx Anda mem-proxy ke port ${PORT_APP:-3000} (app) dan ${PORT_EXT_SERV:-3007} (ext-serv)."
  else
    echo ""
    read -rp "  Jalankan Nginx sekarang? (y/N): " _run_nginx
    if [[ "${_run_nginx,,}" == "y" ]]; then
      echo ""
      echo -e "  ${W}Apakah server ini berada di belakang WAF atau reverse proxy eksternal?${NC}"
      echo -e "  ${DIM}(FortiWeb, F5, Nginx eksternal, load balancer instansi, dll.)${NC}"
      echo -e "  ${DIM}Jika YA : SSL dihandle WAF, Nginx cukup HTTP — tidak butuh sertifikat.${NC}"
      echo -e "  ${DIM}Jika TIDAK: Nginx handle SSL sendiri — butuh sertifikat (self-signed/BSrE/Let's Encrypt).${NC}"
      read -rp "  Pakai WAF/reverse proxy? (y/N): " _use_waf
      if [[ "${_use_waf,,}" == "y" ]]; then
        info "Mode WAF — Nginx dikonfigurasi HTTP-only..."
        _waf_update_http_conf
        if [[ -f "config/nginx/conf.d/geomdb-ssl.conf" ]]; then
          mv "config/nginx/conf.d/geomdb-ssl.conf" \
             "config/nginx/conf.d/geomdb-ssl.conf.disabled"
          ok "SSL config dinonaktifkan (tidak diperlukan di mode WAF)."
        fi
        ok "Pastikan WAF/proxy meneruskan traffic ke port 80 server ini."
      else
        mkdir -p "$CERTS_DIR"
        if ! _ssl_cert_exists; then
          warn "SSL cert belum ada — membuat self-signed otomatis untuk memulai Nginx..."
          _ssl_self_signed_auto
          warn "Jalankan menu 'Konfigurasi SSL' untuk mengganti dengan sertifikat asli."
        fi
      fi
      if docker compose ps nginx 2>/dev/null | grep -q "running"; then
        docker compose exec nginx nginx -t && \
          docker compose exec nginx nginx -s reload && ok "Nginx reloaded."
      else
        docker compose up -d --no-deps nginx && ok "Nginx started."
      fi
    else
      warn "Nginx dan Certbot dilewati."
      info "Jalankan menu 'Konfigurasi SSL' jika ingin mengaktifkan Nginx nanti."
    fi
  fi

  ok "Deploy ${env} selesai! $(date '+%Y-%m-%d %H:%M:%S')"
}

# ─── 4. Clean Docker ──────────────────────────────────────────────────────────
fn_clean_docker() {
  echo -e "\n${W}  Clean Docker${NC}"
  echo "  ─────────────────────────────"
  echo -e "  ${Y}Ini akan menghapus:${NC}"
  echo "   • Semua image yang tidak dipakai"
  echo "   • Semua container yang sudah stop"
  echo "   • Semua network yang tidak dipakai"
  echo "   • Build cache"
  echo ""
  echo -e "  ${R}Volume TIDAK akan dihapus.${NC}"
  echo ""
  read -rp "  Lanjutkan? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; return; }

  info "docker system prune -f (tanpa volume)..."
  docker system prune -f
  ok "Docker cleaned."

  # Tampilkan sisa penggunaan disk
  echo ""
  docker system df
}

# ─── 5. Manajemen Migrasi DB ──────────────────────────────────────────────────
fn_db_menu() {
  while true; do
    echo -e "\n${W}  Manajemen Migrasi DB${NC}"
    echo "  ─────────────────────────────"
    echo "  1) Status migrasi"
    echo "  2) Jalankan migrasi pending (migrate deploy)"
    echo "  3) Seed data awal (db:seed) — hanya untuk install pertama"
    echo "  4) Buat migrasi baru (migrate dev)"
    echo "  5) Reset DB — HAPUS SEMUA DATA"
    echo "  6) Buka Prisma Studio"
    echo "  0) Kembali"
    echo ""
    read -rp "  Pilih: " choice

    case $choice in
      1)
        info "Status migrasi:"
        docker compose run --rm migrate npx prisma migrate status
        ;;
      2)
        confirm_production "migrate deploy" || continue
        load_env
        docker compose run --rm migrate && ok "Migrasi selesai."
        ;;
      3)
        echo -e "  ${Y}Seed akan mengisi data awal (user admin, settings default).${NC}"
        echo -e "  ${Y}Jalankan hanya sekali saat install pertama kali.${NC}"
        read -rp "  Lanjutkan? (y/N): " confirm
        [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; continue; }
        info "Memastikan schema DB ter-apply (db push)..."
        docker compose run --rm migrate || { err "Schema DB gagal diapply."; continue; }
        docker compose run --rm migrate npx tsx prisma/seed.ts && ok "Seed selesai."
        ;;
      4)
        if [[ "$(get_env)" == "production" ]]; then
          err "migrate dev tidak boleh di production! Gunakan migrate deploy."
          continue
        fi
        read -rp "  Nama migrasi: " mig_name
        [[ -z "$mig_name" ]] && { warn "Nama kosong."; continue; }
        docker compose run --rm migrate npx prisma migrate dev --name "$mig_name"
        ok "Migrasi '$mig_name' dibuat."
        ;;
      5)
        if [[ "$(get_env)" == "production" ]]; then
          err "RESET TIDAK DIIZINKAN DI PRODUCTION!"
          continue
        fi
        echo -e "  ${R}⚠ SEMUA DATA AKAN DIHAPUS! ⚠${NC}"
        read -rp "  Ketik 'RESET' untuk konfirmasi: " confirm
        [[ "$confirm" == "RESET" ]] || { warn "Dibatalkan."; continue; }
        docker compose run --rm migrate npx prisma db push --force-reset
        warn "DB di-reset (schema diapply ulang). Jalankan seed (opsi 3) jika perlu."
        ;;
      6)
        info "Membuka Prisma Studio di http://localhost:5555 ..."
        docker compose run --rm -p 5555:5555 migrate npx prisma studio
        ;;
      0) return ;;
      *) warn "Pilihan tidak valid." ;;
    esac
  done
}

# ─── 6. Flush Redis ───────────────────────────────────────────────────────────
fn_flush_redis() {
  echo -e "\n${W}  Flush Redis${NC}"
  echo "  ─────────────────────────────"
  echo "  1) Flush cache CSW saja   (DEL csw:*)"
  echo "  2) Flush JWT blacklist    (DEL jwt:blacklist:*)"
  echo "  3) Flush semua           (FLUSHDB)"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih: " choice

  case $choice in
    1)
      local count
      count=$(docker compose exec redis redis-cli --scan --pattern 'csw:*' | wc -l)
      info "Menghapus $count key CSW cache..."
      docker compose exec redis redis-cli --scan --pattern 'csw:*' | \
        xargs -r docker compose exec -T redis redis-cli DEL
      ok "CSW cache dihapus."
      ;;
    2)
      local count
      count=$(docker compose exec redis redis-cli --scan --pattern 'jwt:blacklist:*' | wc -l)
      info "Menghapus $count key JWT blacklist..."
      docker compose exec redis redis-cli --scan --pattern 'jwt:blacklist:*' | \
        xargs -r docker compose exec -T redis redis-cli DEL
      ok "JWT blacklist dihapus."
      ;;
    3)
      confirm_production "FLUSHDB Redis" || return
      echo -e "  ${Y}Ini menghapus SEMUA data Redis termasuk JWT blacklist.${NC}"
      read -rp "  Lanjutkan? (y/N): " confirm
      [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; return; }
      docker compose exec redis redis-cli FLUSHDB
      ok "Redis FLUSHDB selesai."
      ;;
    0) return ;;
    *) warn "Pilihan tidak valid." ;;
  esac
}

# ─── 7. Backup & Restore ─────────────────────────────────────────────────────
fn_backup_menu() {
  echo -e "\n${W}  Backup & Restore${NC}"
  echo "  ─────────────────────────────"
  echo "  1) Backup database sekarang"
  echo "  2) Lihat daftar backup"
  echo "  3) Restore dari backup"
  echo "  4) Setup crontab backup otomatis harian jam 02:00"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih: " choice

  local backup_dir="${BACKUP_DIR:-/backup/geomdb}"

  case $choice in
    1)
      mkdir -p "$backup_dir"
      local ts; ts=$(date +%Y%m%d_%H%M%S)
      local file="$backup_dir/geomdb_hub_${ts}.sql.gz"
      info "Backup database ke ${file}..."
      if docker compose exec -T postgres pg_dump -U geomdb geomdb_hub | gzip > "$file"; then
        ok "Backup selesai: $(du -sh "$file" | cut -f1) — $file"
      else
        err "Backup gagal."
      fi
      ;;
    2)
      if [ -d "$backup_dir" ]; then
        echo ""
        ls -lh "$backup_dir"/*.sql.gz 2>/dev/null || warn "Tidak ada backup di $backup_dir"
      else
        warn "Direktori backup belum ada: $backup_dir"
      fi
      ;;
    3)
      if [ ! -d "$backup_dir" ]; then warn "Tidak ada backup di $backup_dir"; return; fi
      echo ""
      local files=("$backup_dir"/*.sql.gz)
      if [ ${#files[@]} -eq 0 ] || [ ! -f "${files[0]}" ]; then
        warn "Tidak ada file backup."
        return
      fi
      for i in "${!files[@]}"; do echo "  $((i+1))) ${files[$i]}"; done
      read -rp "  Pilih nomor backup: " idx
      local sel="${files[$((idx-1))]}"
      if [ ! -f "$sel" ]; then warn "File tidak valid."; return; fi
      confirm_production "RESTORE database dari $sel" || return
      info "Restore dari $sel ..."
      if gunzip -c "$sel" | docker compose exec -T postgres psql -U geomdb geomdb_hub; then
        ok "Restore selesai."
      else
        err "Restore gagal."
      fi
      ;;
    4)
      local cron_cmd="0 2 * * * cd $(pwd) && docker compose exec -T postgres pg_dump -U geomdb geomdb_hub | gzip > ${backup_dir}/geomdb_hub_\$(date +\\%Y\\%m\\%d_\\%H\\%M\\%S).sql.gz && find ${backup_dir} -name '*.sql.gz' -mtime +30 -delete"
      info "Menambahkan crontab backup harian..."
      mkdir -p "$backup_dir"
      ( crontab -l 2>/dev/null | grep -v "geomdb_hub"; echo "$cron_cmd" ) | crontab -
      ok "Crontab backup ditambahkan:"
      echo "  $cron_cmd"
      ;;
    0) return ;;
    *) warn "Pilihan tidak valid." ;;
  esac
}

# ─── 8. Konfigurasi SSL ───────────────────────────────────────────────────────
CERTS_DIR="config/nginx/certs"

_ssl_cert_exists() { [[ -f "$CERTS_DIR/cert.pem" ]]; }

_ssl_info() {
  if ! _ssl_cert_exists; then
    warn "Belum ada sertifikat di $CERTS_DIR/cert.pem"
    return
  fi
  echo -e "\n${W}  Info Sertifikat Aktif${NC}"
  echo "  ─────────────────────────────────────────────"
  openssl x509 -noout \
    -subject -issuer -dates \
    -in "$CERTS_DIR/cert.pem" 2>/dev/null | sed 's/^/  /'

  echo ""
  echo -e "${W}  Domain yang dicakup (SAN):${NC}"
  openssl x509 -noout -ext subjectAltName \
    -in "$CERTS_DIR/cert.pem" 2>/dev/null \
    | grep -oP 'DNS:[^,\n]+' | sed 's/DNS:/  • /' || echo "  (tidak ada SAN)"

  # Cek sisa hari
  local expiry days_left
  expiry=$(openssl x509 -noout -enddate -in "$CERTS_DIR/cert.pem" \
    | cut -d= -f2)
  days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || \
                   date -j -f "%b %d %T %Y %Z" "$expiry" +%s) \
                  - $(date +%s) ) / 86400 ))

  if   (( days_left <= 14 )); then
    echo -e "\n  ${R}⚠ Sertifikat kedaluwarsa dalam $days_left hari!${NC}"
  elif (( days_left <= 30 )); then
    echo -e "\n  ${Y}⚠ Sertifikat kedaluwarsa dalam $days_left hari.${NC}"
  else
    echo -e "\n  ${G}✓ Sertifikat valid selama $days_left hari lagi.${NC}"
  fi
  echo "  ─────────────────────────────────────────────"
}

_ssl_dhparam() {
  if [[ -f "$CERTS_DIR/dhparam.pem" ]]; then
    ok "DH parameters sudah ada, skip."; return
  fi
  info "Membuat DH parameters 2048-bit (±30 detik)..."
  openssl dhparam -out "$CERTS_DIR/dhparam.pem" 2048 2>/dev/null
  ok "DH parameters dibuat."
}

# Non-interaktif — dipakai otomatis saat deploy pertama kali
_ssl_self_signed_auto() {
  mkdir -p "$CERTS_DIR"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "$CERTS_DIR/key.pem" \
    -out    "$CERTS_DIR/cert.pem" \
    -subj   "/C=ID/O=Geomdb Hub/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    2>/dev/null
  _ssl_dhparam
  ok "Self-signed cert dibuat. Ganti dengan cert asli via menu 'Konfigurasi SSL'."
}

_ssl_nginx_reload() {
  if docker compose ps nginx 2>/dev/null | grep -q "running"; then
    docker compose exec nginx nginx -t && \
    docker compose exec nginx nginx -s reload && \
    ok "Nginx reloaded." || err "Konfigurasi nginx ada error!"
  else
    info "Nginx belum jalan — memulai nginx..."
    docker compose up -d --no-deps nginx && ok "Nginx started." || err "Gagal menjalankan nginx!"
  fi
}

# ── 7a. Self-signed (dev / internal) ──────────────────────────────────────────
_ssl_self_signed() {
  echo -e "\n${W}  Self-Signed Certificate${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${Y}Gratis, tapi browser akan tampilkan peringatan.${NC}"
  echo "  Cocok untuk: development, jaringan internal, testing."
  echo ""
  read -rp "  Domain (default: localhost): " domain
  domain="${domain:-localhost}"
  mkdir -p "$CERTS_DIR"

  info "Generate sertifikat untuk: $domain"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "$CERTS_DIR/key.pem" \
    -out    "$CERTS_DIR/cert.pem" \
    -subj   "/C=ID/ST=DKI Jakarta/L=Jakarta/O=Geomdb Hub/CN=$domain" \
    -addext "subjectAltName=DNS:$domain,DNS:localhost,IP:127.0.0.1" \
    2>/dev/null
  ok "Sertifikat self-signed dibuat."
  _ssl_dhparam
  _ssl_nginx_reload
}

# ── 7b. Let's Encrypt — HTTP challenge (domain tunggal, gratis) ───────────────
_ssl_letsencrypt_http() {
  echo -e "\n${W}  Let's Encrypt — HTTP Challenge${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${G}Gratis. Browser trust penuh.${NC}"
  echo "  Syarat: port 80 terbuka, domain sudah mengarah ke server ini."
  echo ""
  read -rp "  Domain (contoh: metadata.instansi.go.id): " domain
  read -rp "  Email admin: " email
  [[ -z "$domain" || -z "$email" ]] && { warn "Domain dan email wajib diisi."; return; }

  mkdir -p "$CERTS_DIR"
  info "Menerbitkan sertifikat via webroot challenge..."

  # Jalankan certbot — pakai docker jika tersedia, fallback ke host
  local certbot_cmd
  if docker compose ps nginx 2>/dev/null | grep -q "running"; then
    certbot_cmd="docker compose --profile certbot run --rm certbot"
  elif command -v certbot &>/dev/null; then
    certbot_cmd="certbot"
  else
    err "certbot tidak ditemukan. Pastikan nginx jalan (untuk Docker certbot) atau install certbot."
    return
  fi

  $certbot_cmd certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    -d "$domain" || { err "Certbot gagal."; return; }

  # Salin cert ke nginx certs dir
  _ssl_copy_le_certs "$domain"
  _ssl_dhparam
  _ssl_nginx_reload
  ok "Let's Encrypt HTTP selesai. Sertifikat berlaku 90 hari."
}

# ── 7c. Let's Encrypt — DNS challenge (wildcard, gratis) ─────────────────────
_ssl_letsencrypt_dns() {
  echo -e "\n${W}  Let's Encrypt — DNS Challenge (Wildcard)${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${G}Gratis. Satu cert untuk semua subdomain (*.domain.go.id).${NC}"
  echo -e "  ${Y}Syarat: akses ke panel DNS domain tersebut.${NC}"
  echo ""
  read -rp "  Root domain (contoh: instansi.go.id): " domain_root
  read -rp "  Email admin: " email
  [[ -z "$domain_root" || -z "$email" ]] && { warn "Domain dan email wajib diisi."; return; }

  mkdir -p "$CERTS_DIR"

  echo ""
  echo -e "  ${C}Certbot akan meminta Anda menambahkan DNS TXT record.${NC}"
  echo "  Buka panel DNS domain Anda dan siapkan sebelum melanjutkan."
  echo ""
  read -rp "  Siap? Tekan Enter untuk mulai..." _

  # Jalankan certbot manual DNS challenge
  local certbot_cmd
  if command -v certbot &>/dev/null; then
    certbot_cmd="certbot"
  elif docker compose --profile certbot run --rm certbot --version &>/dev/null 2>&1; then
    certbot_cmd="docker compose --profile certbot run --rm --entrypoint='' certbot certbot"
  else
    err "certbot tidak ditemukan."
    return
  fi

  $certbot_cmd certonly \
    --manual \
    --preferred-challenges dns \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    -d "*.${domain_root}" \
    -d "${domain_root}" || { err "Certbot gagal."; return; }

  # Salin cert ke nginx certs dir
  _ssl_copy_le_certs "$domain_root"
  _ssl_dhparam

  # Aktifkan ssl_trusted_certificate untuk OCSP stapling
  if [[ -f "$CERTS_DIR/chain.pem" ]]; then
    sed -i 's|# ssl_trusted_certificate|ssl_trusted_certificate|g' \
      config/nginx/conf.d/geomdb-ssl.conf 2>/dev/null || true
    ok "OCSP stapling diaktifkan."
  fi

  _ssl_nginx_reload
  ok "Let's Encrypt Wildcard *.${domain_root} selesai!"
  warn "Perpanjangan wildcard harus manual — jalankan menu 'Perpanjang sertifikat' tiap 60 hari."
}

_ssl_copy_le_certs() {
  local domain="$1"
  local le_live="/etc/letsencrypt/live/$domain"

  info "Menyalin cert ke $CERTS_DIR ..."

  # Coba salin via Docker certbot container
  if docker compose --profile certbot run --rm --entrypoint="" certbot \
    sh -c "cp ${le_live}/fullchain.pem /certs/cert.pem && \
           cp ${le_live}/chain.pem     /certs/chain.pem && \
           cp ${le_live}/privkey.pem   /certs/key.pem" 2>/dev/null; then
    ok "Cert disalin via Docker."
  # Fallback: salin langsung dari host (jika certbot di host)
  elif [[ -d "$le_live" ]]; then
    cp "${le_live}/fullchain.pem" "$CERTS_DIR/cert.pem"
    cp "${le_live}/chain.pem"     "$CERTS_DIR/chain.pem"
    cp "${le_live}/privkey.pem"   "$CERTS_DIR/key.pem"
    chmod 600 "$CERTS_DIR/key.pem"
    ok "Cert disalin dari host."
  else
    err "Tidak bisa menyalin cert. Salin manual dari /etc/letsencrypt/live/$domain/"
  fi
}

# ── 7d. Sertifikat komersial (DigiCert/GeoTrust/Comodo/BSrE) ─────────────────
_ssl_commercial() {
  echo -e "\n${W}  Sertifikat Komersial${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${C}Berbayar — DigiCert, GeoTrust, Sectigo, Comodo, BSrE BSSN${NC}"
  echo "  Mendukung wildcard, chain penuh, OCSP stapling."
  echo ""

  echo "  Format file dari CA:"
  echo "  1) cert.pem + chain.pem + privkey.pem  (standar / Let's Encrypt style)"
  echo "  2) certificate.crt + ca_bundle.crt + private.key  (cPanel/DigiCert download)"
  echo "  3) .pfx / .p12  (format Windows/IIS)"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih format: " fmt

  mkdir -p "$CERTS_DIR"

  case $fmt in
    1|2)
      if [[ "$fmt" == "1" ]]; then
        read -rp "  Path cert.pem    : " f_cert
        read -rp "  Path chain.pem   : " f_chain
        read -rp "  Path privkey.pem : " f_key
      else
        read -rp "  Path certificate.crt  : " f_cert
        read -rp "  Path ca_bundle.crt    : " f_chain
        read -rp "  Path private.key      : " f_key
      fi
      for f in "$f_cert" "$f_chain" "$f_key"; do
        [[ -f "$f" ]] || { err "File tidak ditemukan: $f"; return; }
      done
      info "Membuat fullchain..."
      cat "$f_cert" "$f_chain" > "$CERTS_DIR/cert.pem"
      cp  "$f_chain" "$CERTS_DIR/chain.pem"
      cp  "$f_key"   "$CERTS_DIR/key.pem"
      ;;
    3)
      read -rp "  Path file .pfx/.p12 : " f_pfx
      [[ -f "$f_pfx" ]] || { err "File tidak ditemukan: $f_pfx"; return; }
      info "Extract dari .pfx..."
      openssl pkcs12 -in "$f_pfx" -nocerts -nodes \
        -out "$CERTS_DIR/key.pem" 2>/dev/null
      openssl pkcs12 -in "$f_pfx" -nokeys \
        -out "$CERTS_DIR/cert.pem" 2>/dev/null
      warn "Tidak ada chain.pem terpisah — OCSP stapling perlu dikonfigurasi manual."
      ;;
    0) return ;;
    *) warn "Format tidak valid."; return ;;
  esac

  # Validasi cert & key cocok
  info "Validasi cert dan key..."
  local cm km
  cm=$(openssl x509 -noout -modulus -in "$CERTS_DIR/cert.pem" | openssl md5)
  km=$(openssl rsa  -noout -modulus -in "$CERTS_DIR/key.pem"  | openssl md5)
  [[ "$cm" == "$km" ]] || { err "Certificate dan private key TIDAK cocok!"; return; }
  ok "Certificate dan private key cocok."

  # Aktifkan OCSP stapling jika ada chain
  if [[ -f "$CERTS_DIR/chain.pem" ]]; then
    sed -i 's|# ssl_trusted_certificate|ssl_trusted_certificate|g' \
      config/nginx/conf.d/geomdb-ssl.conf 2>/dev/null || true
    ok "OCSP stapling diaktifkan."
  fi

  _ssl_dhparam
  chmod 600 "$CERTS_DIR/key.pem"
  chmod 644 "$CERTS_DIR/cert.pem" "$CERTS_DIR/chain.pem" 2>/dev/null || true

  _ssl_info
  _ssl_nginx_reload
}

# ── 7e. Perpanjang sertifikat (certbot renew) ─────────────────────────────────
_ssl_renew() {
  echo -e "\n${W}  Perpanjang Sertifikat${NC}"
  echo "  ─────────────────────────────────────────────"
  _ssl_info

  read -rp "  Perpanjang sekarang? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; return; }

  if command -v certbot &>/dev/null; then
    certbot renew --quiet && ok "Certbot renew selesai."
    # Salin ulang cert terbaru
    local domain
    domain=$(openssl x509 -noout -subject -in "$CERTS_DIR/cert.pem" \
      | grep -oP 'CN\s*=\s*\K[^,]+' | sed 's/^\*\.//' || true)
    [[ -n "$domain" ]] && _ssl_copy_le_certs "$domain"
  elif docker compose --profile certbot ps certbot &>/dev/null 2>&1; then
    docker compose --profile certbot run --rm certbot renew --quiet
    ok "Certbot renew (Docker) selesai."
  else
    err "certbot tidak tersedia. Perpanjang manual di server."
    return
  fi

  _ssl_nginx_reload
}

# ── 7f. Konfigurasi WAF ───────────────────────────────────────────────────────
REAL_IP_CONF="config/nginx/conf.d/real-ip.conf"

_waf_status() {
  if grep -q "^set_real_ip_from" "$REAL_IP_CONF" 2>/dev/null; then
    local count
    count=$(grep -c "^set_real_ip_from" "$REAL_IP_CONF" 2>/dev/null || echo 0)
    echo -e "  WAF    : ${G}Aktif — $count IP/subnet dipercaya${NC}"
  else
    echo -e "  WAF    : ${DIM}Tidak dikonfigurasi${NC}"
  fi

  # Cek mode nginx — apakah SSL aktif atau HTTP-only
  if [[ -f "config/nginx/conf.d/geomdb-ssl.conf" ]]; then
    echo -e "  Mode   : ${G}HTTPS (SSL di Nginx)${NC}"
  else
    echo -e "  Mode   : ${Y}HTTP-only (SSL di WAF)${NC}"
  fi
}

_waf_configure() {
  echo -e "\n${W}  Konfigurasi WAF${NC}"
  echo "  ─────────────────────────────────────────────"
  echo ""
  echo -e "  ${W}Skenario WAF yang tersedia:${NC}"
  echo ""
  echo -e "  ${C}A)${NC} SSL Termination di WAF ${DIM}(paling umum)${NC}"
  echo -e "     ${DIM}Browser→[HTTPS]→WAF→[HTTP]→Nginx${NC}"
  echo -e "     ${DIM}Cert dipasang di WAF, Nginx tidak perlu cert publik${NC}"
  echo ""
  echo -e "  ${C}B)${NC} SSL Pass-through ${DIM}(WAF inspeksi tanpa dekripsi)${NC}"
  echo -e "     ${DIM}Browser→[HTTPS]→WAF→[HTTPS]→Nginx${NC}"
  echo -e "     ${DIM}Cert tetap di Nginx, gunakan DNS challenge${NC}"
  echo ""
  echo -e "  ${C}C)${NC} SSL Re-encryption ${DIM}(WAF dekripsi + enkripsi ulang)${NC}"
  echo -e "     ${DIM}Browser→[HTTPS]→WAF→[HTTPS]→Nginx${NC}"
  echo -e "     ${DIM}WAF punya cert publik, Nginx pakai self-signed${NC}"
  echo ""
  echo -e "  ${C}D)${NC} Konfigurasi IP WAF ${DIM}(tambah/edit IP yang dipercaya)${NC}"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih skenario: " choice

  case $choice in
    A|a) _waf_ssl_termination ;;
    B|b) _waf_passthrough ;;
    C|c) _waf_reencrypt ;;
    D|d) _waf_set_ips ;;
    0)   return ;;
    *)   warn "Pilihan tidak valid." ;;
  esac
}

_waf_ssl_termination() {
  echo -e "\n${W}  WAF — SSL Termination${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${Y}Mode ini: cert ada di WAF, Nginx terima HTTP dari WAF.${NC}"
  echo ""
  echo "  Yang akan dilakukan:"
  echo "  1. Nginx dikonfigurasi HTTP-only (tidak pakai cert)"
  echo "  2. Real IP dari WAF dikonfigurasi"
  echo "  3. Header X-Forwarded-Proto diteruskan ke Next.js"
  echo ""
  read -rp "  Lanjutkan? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; return; }

  # Nonaktifkan geomdb-ssl.conf (rename jadi .disabled)
  if [[ -f "config/nginx/conf.d/geomdb-ssl.conf" ]]; then
    mv "config/nginx/conf.d/geomdb-ssl.conf" \
       "config/nginx/conf.d/geomdb-ssl.conf.disabled"
    ok "SSL config dinonaktifkan (geomdb-ssl.conf.disabled)"
  fi

  # Update geomdb.conf — hapus redirect, langsung proxy
  _waf_update_http_conf
  _waf_set_ips
  _ssl_nginx_reload

  echo ""
  echo -e "  ${W}Langkah selanjutnya:${NC}"
  echo "  • Pasang sertifikat publik di panel WAF (bukan di server ini)"
  echo "  • Pastikan WAF meneruskan header X-Forwarded-For ke Nginx"
  echo "  • Untuk Let's Encrypt: pakai validasi DNS (tidak butuh port 80)"
  warn "Rate limiting sekarang memakai IP WAF sampai real-ip.conf dikonfigurasi."
}

_waf_passthrough() {
  echo -e "\n${W}  WAF — SSL Pass-through${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${G}Mode ini: Nginx tetap handle SSL, WAF hanya inspeksi.${NC}"
  echo ""
  echo "  Yang perlu dilakukan:"
  echo "  • Cert tetap dipasang di Nginx (menu a/b/c/d)"
  echo "  • Konfigurasi IP WAF agar real IP client terbaca"
  echo ""

  # Pastikan geomdb-ssl.conf aktif
  if [[ -f "config/nginx/conf.d/geomdb-ssl.conf.disabled" ]]; then
    mv "config/nginx/conf.d/geomdb-ssl.conf.disabled" \
       "config/nginx/conf.d/geomdb-ssl.conf"
    ok "SSL config diaktifkan kembali."
  fi

  _waf_set_ips

  echo ""
  echo -e "  ${Y}Rekomendasi SSL dengan WAF pass-through:${NC}"
  echo "  • Let's Encrypt DNS challenge (opsi c) — paling kompatibel"
  echo "  • Sertifikat komersial (opsi d) — jika instansi sudah punya"
  echo -e "  • ${R}Hindari Let's Encrypt HTTP${NC} — WAF mungkin blokir /.well-known/"
  _ssl_nginx_reload
}

_waf_reencrypt() {
  echo -e "\n${W}  WAF — SSL Re-encryption${NC}"
  echo "  ─────────────────────────────────────────────"
  echo -e "  ${C}Mode ini: WAF punya cert publik, Nginx pakai self-signed.${NC}"
  echo "  WAF-ke-Nginx tetap terenkripsi HTTPS."
  echo ""
  echo "  Yang akan dilakukan:"
  echo "  • Generate self-signed cert untuk koneksi WAF→Nginx"
  echo "  • Nginx tetap listen di HTTPS port 443"
  echo "  • Konfigurasi IP WAF"
  echo ""
  read -rp "  Lanjutkan? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "Dibatalkan."; return; }

  # Pastikan geomdb-ssl.conf aktif
  if [[ -f "config/nginx/conf.d/geomdb-ssl.conf.disabled" ]]; then
    mv "config/nginx/conf.d/geomdb-ssl.conf.disabled" \
       "config/nginx/conf.d/geomdb-ssl.conf"
  fi

  # Generate self-signed untuk backend
  read -rp "  IP/hostname server ini (untuk SAN cert): " server_ip
  server_ip="${server_ip:-$(hostname -I | awk '{print $1}')}"

  mkdir -p "$CERTS_DIR"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "$CERTS_DIR/key.pem" \
    -out    "$CERTS_DIR/cert.pem" \
    -subj   "/C=ID/O=Geomdb Hub Backend/CN=backend" \
    -addext "subjectAltName=IP:$server_ip,IP:127.0.0.1" \
    2>/dev/null
  ok "Self-signed cert untuk backend dibuat (IP: $server_ip)"
  _ssl_dhparam
  _waf_set_ips
  _ssl_nginx_reload

  echo ""
  echo -e "  ${W}Langkah selanjutnya:${NC}"
  echo "  • Import cert.pem ke WAF sebagai 'trusted backend cert'"
  echo "  • Pasang sertifikat publik (dari CA) di panel WAF"
  echo "  • WAF akan re-encrypt traffic ke Nginx pakai self-signed ini"
}

_waf_update_http_conf() {
  # Update geomdb.conf.template agar tidak redirect ke HTTPS (karena WAF sudah handle)
  local conf="config/nginx/conf.d/geomdb.conf.template"
  if grep -q "Mode WAF" "$conf" 2>/dev/null; then
    ok "Nginx sudah dalam mode WAF — template tidak diubah."
    return
  fi
  cat > "$conf" << 'NGINXCONF'
# ─── Upstream — container Next.js ────────────────────────────────────────────
upstream nextjs {
    server app:${PORT_APP};
    keepalive 16;
}

# ─── HTTP — Mode WAF SSL Termination ──────────────────────────────────────────
# SSL dihandle WAF/reverse proxy eksternal. Nginx terima HTTP dari WAF.
# X-Forwarded-Proto di-hardcode "https" karena WAF selalu terminate HTTPS.
server {
    listen 80 default_server;
    server_name _;

    # Let's Encrypt webroot challenge (tidak aktif di mode WAF, tidak mengganggu)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    client_max_body_size 100m;

    # ─── CSW endpoint ──────────────────────────────────────────────────────────
    location /csw {
        limit_req zone=csw burst=30 nodelay;
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout      120s;
        proxy_send_timeout      60s;
        proxy_buffer_size       256k;
        proxy_buffers           8 256k;
        proxy_busy_buffers_size 512k;
    }

    # ─── Public API — cacheable oleh browser & CDN ───────────────────────────
    location ~* ^/(api/public/|api/standar/|api/dokumentasi/) {
        limit_req zone=api burst=80 nodelay;
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        add_header Cache-Control "public, max-age=60, stale-while-revalidate=300" always;
        proxy_read_timeout 30s;
    }

    # ─── Next.js static assets — cache 1 tahun ───────────────────────────────
    location /_next/static/ {
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }

    # ─── WhatsApp SSE — koneksi long-lived, jangan dibuffer ──────────────────
    location ~ /api/admin/organisasi/wa/connect$ {
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 200s;
        proxy_send_timeout 200s;
    }

    # ─── Admin sync (timeout panjang untuk dataset besar) ─────────────────────
    location /api/admin/csw/sync {
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    # ─── Login & OTP — brute force protection ────────────────────────────────
    location /api/auth/otp/ {
        limit_req zone=auth burst=5 nodelay;
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
    }

    location /api/auth/login {
        limit_req zone=auth burst=5 nodelay;
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
    }

    # ─── Dokumen PDF ──────────────────────────────────────────────────────────
    location ~ ^/api/metadata/[^/]+/(qcqe/pdf|pemeriksa/spd)$ {
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 30s;
    }

    # ─── API umum ─────────────────────────────────────────────────────────────
    location /api/ {
        limit_req zone=api burst=80 nodelay;
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 30s;
    }

    # ─── Block script/exploit probing ─────────────────────────────────────────
    location ~* \.(php|php5|php7|phtml|asp|aspx|cgi|sh|py|pl|rb|jsp|cfm)$ {
        return 444;
    }
    location ~* ^/(wp-login|wp-admin|wp-includes|xmlrpc|phpmyadmin|pma|myadmin|mysqladmin|adminer|shell|backdoor|eval|base64|webshell|c99|r57|alfa) {
        return 444;
    }
    location ~* /(\.git|\.env|\.htaccess|\.htpasswd|web\.config|composer\.(json|lock)|package\.json|yarn\.lock) {
        return 444;
    }

    # ─── Next.js app ──────────────────────────────────────────────────────────
    location / {
        if ($http_next_action) { return 400; }
        proxy_pass         http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 30s;
    }
}
NGINXCONF
  ok "geomdb.conf.template diupdate ke mode WAF (HTTP-only)."
}

_waf_set_ips() {
  echo -e "\n${W}  Konfigurasi IP WAF${NC}"
  echo "  ─────────────────────────────────────────────"
  echo "  IP/subnet WAF yang akan dipercaya Nginx untuk real IP."
  echo ""

  # Tampilkan IP yang sudah ada
  if grep -q "^set_real_ip_from" "$REAL_IP_CONF" 2>/dev/null; then
    echo -e "  ${W}IP/subnet yang sudah dikonfigurasi:${NC}"
    grep "^set_real_ip_from" "$REAL_IP_CONF" | sed 's/set_real_ip_from/  •/' | sed 's/;//'
    echo ""
  fi

  echo "  Pilih tipe WAF untuk menambahkan IP:"
  echo "  1) WAF internal / on-premise (10.x / 172.16.x / 192.168.x)"
  echo "  2) Cloudflare WAF"
  echo "  3) Input IP/subnet manual"
  echo "  4) Lihat file konfigurasi"
  echo "  0) Selesai"
  echo ""
  read -rp "  Pilih: " waf_choice

  case $waf_choice in
    1)
      # Sudah ada di real-ip.conf secara default
      ok "IP jaringan internal (10/172.16/192.168) sudah aktif."
      ;;
    2)
      info "Mengaktifkan IP range Cloudflare..."
      # Uncomment semua baris Cloudflare
      sed -i 's|^# set_real_ip_from  10[0-9]|set_real_ip_from  10\0|g' \
        "$REAL_IP_CONF" 2>/dev/null || true
      sed -i '/Cloudflare/,/^$/ s/^# set_real_ip_from/set_real_ip_from/' \
        "$REAL_IP_CONF" 2>/dev/null || true
      ok "IP Cloudflare diaktifkan."
      ;;
    3)
      read -rp "  Masukkan IP atau subnet (contoh: 203.0.113.10 atau 10.10.1.0/24): " waf_ip
      [[ -z "$waf_ip" ]] && { warn "IP kosong."; return; }
      # Tambahkan setelah baris internal subnet terakhir
      sed -i "/^set_real_ip_from  192\.168/a set_real_ip_from  ${waf_ip};" \
        "$REAL_IP_CONF" 2>/dev/null || \
      echo "set_real_ip_from  ${waf_ip};" >> "$REAL_IP_CONF"
      ok "IP $waf_ip ditambahkan."
      ;;
    4)
      echo ""
      cat "$REAL_IP_CONF"
      ;;
    0) return ;;
  esac

  _ssl_nginx_reload
}

# ── 7g. Test & reload nginx ───────────────────────────────────────────────────
_ssl_nginx_test() {
  info "Test konfigurasi nginx..."
  if docker compose exec nginx nginx -t; then
    ok "Konfigurasi nginx valid."
  else
    err "Ada error di konfigurasi nginx! Periksa config/nginx/conf.d/"
  fi
}

# ── Menu utama SSL ─────────────────────────────────────────────────────────────
fn_ssl_menu() {
  while true; do
    echo -e "\n${W}  Konfigurasi SSL${NC}"
    echo "  ─────────────────────────────────────────────"

    # Status cert singkat di header submenu
    if _ssl_cert_exists; then
      local expiry days_left
      expiry=$(openssl x509 -noout -enddate -in "$CERTS_DIR/cert.pem" \
        | cut -d= -f2 2>/dev/null)
      days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || \
                       date -j -f "%b %d %T %Y %Z" "$expiry" +%s) \
                      - $(date +%s) ) / 86400 ))
      local issuer
      issuer=$(openssl x509 -noout -issuer -in "$CERTS_DIR/cert.pem" \
        2>/dev/null | grep -oP 'O\s*=\s*\K[^,/]+' | head -1)

      local status_color=$G
      (( days_left <= 30 )) && status_color=$Y
      (( days_left <= 14 )) && status_color=$R

      printf "  Status : ${status_color}%s — %d hari tersisa${NC}\n" \
        "${issuer:-Unknown CA}" "$days_left"
    else
      echo -e "  Status : ${Y}Belum ada sertifikat${NC}"
    fi

    _waf_status
    echo "  ─────────────────────────────────────────────"
    echo ""
    echo "  Pilih jenis sertifikat:"
    echo ""
    echo -e "  ${Y}a)${NC} Self-signed            ${DIM}(gratis, browser warning, dev/internal)${NC}"
    echo -e "  ${G}b)${NC} Let's Encrypt HTTP      ${DIM}(gratis, domain tunggal, port 80 harus buka)${NC}"
    echo -e "  ${G}c)${NC} Let's Encrypt DNS       ${DIM}(gratis, wildcard *.domain, butuh akses DNS)${NC}"
    echo -e "  ${C}d)${NC} Komersial               ${DIM}(berbayar: DigiCert/GeoTrust/Comodo/BSrE)${NC}"
    echo ""
    echo "  Manajemen:"
    echo "  1) Info sertifikat aktif"
    echo "  2) Perpanjang sertifikat (certbot renew)"
    echo "  3) Test konfigurasi nginx"
    echo "  4) Reload nginx"
    echo -e "  ${B}5) Konfigurasi WAF${NC}         ${DIM}(SSL termination / pass-through / real IP)${NC}"
    echo "  0) Kembali ke menu utama"
    echo ""
    read -rp "  Pilih: " choice

    case $choice in
      a|A) _ssl_self_signed ;;
      b|B) _ssl_letsencrypt_http ;;
      c|C) _ssl_letsencrypt_dns ;;
      d|D) _ssl_commercial ;;
      1)   _ssl_info ;;
      2)   _ssl_renew ;;
      3)   _ssl_nginx_test ;;
      4)   _ssl_nginx_reload ;;
      5)   _waf_configure ;;
      0)   return ;;
      *)   warn "Pilihan tidak valid." ;;
    esac

    echo ""
    read -rp "  Tekan Enter untuk kembali ke menu SSL..." _
  done
}

# ─── Main menu ────────────────────────────────────────────────────────────────
# ─── 3b. Deploy Lokal (tanpa Nginx) ──────────────────────────────────────────
fn_deploy_local() {
  load_env

  local port="${PORT_APP:-3000}"
  echo -e "\n${W}  Deploy Lokal${NC} — akses di ${C}http://localhost:${port}${NC}"
  echo "  ─────────────────────────────"

  # Pilih cara instalasi image aplikasi
  _pick_install_method

  # 1. Infra (postgres, redis, minio, pycsw)
  # Mode tarball (offline): skip pull — gunakan image yang sudah ada di cache lokal.
  # Jika belum pernah di-pull, jalankan sekali: docker compose pull postgres redis minio pycsw
  if [[ "${INSTALL_METHOD:-local}" != "tarball" ]]; then
    info "Pull image infra terbaru..."
    docker compose pull postgres redis minio pycsw
  else
    info "Mode offline (tarball) — memeriksa cache image infra..."
    _ensure_infra_images || return 1
  fi
  # ext_serv-main/.env opsional (konfigurasi WA extra), tapi wajib ada sebagai file
  # agar kompatibel dengan Compose versi lama yang tidak support {path,required} syntax
  mkdir -p ext_serv-main && touch ext_serv-main/.env

  docker compose up -d --remove-orphans postgres redis minio pycsw
  ok "Infra containers running."

  # 2. Siapkan image app/migrate/ext-serv
  if [[ "${INSTALL_METHOD:-local}" == "local" ]]; then
    _build_compose "ext-serv + migrator" ext-serv migrate || return 1
  else
    _apply_install_method || return 1
  fi

  # 3. Tunggu postgres healthy
  info "Menunggu postgres healthy..."
  local tries=0
  until docker compose exec -T postgres pg_isready -U geomdb -d geomdb_hub &>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -ge 30 ]] && { err "Postgres tidak ready setelah 60 detik."; return 1; }
    sleep 2
  done
  ok "Postgres ready."

  # 4. Migrasi DB
  info "Jalankan migrasi DB..."
  docker compose run --rm migrate && ok "Migrasi selesai."

  # 5. Auto-seed jika database masih kosong
  info "Memeriksa apakah database perlu di-seed..."
  local user_count
  user_count=$(docker compose exec -T postgres psql -U geomdb -d geomdb_hub -tAq \
    -c 'SELECT COUNT(*) FROM "User";' 2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "$user_count" == "0" ]]; then
    info "Database kosong — menjalankan seed data awal..."
    docker compose run --rm migrate npx tsx prisma/seed.ts && ok "Seed selesai."
  else
    info "Database sudah berisi data ($user_count user) — seed awal dilewati."
    # Saat upgrade: perbarui HANYA dokumentasi (panduan + FAQ) agar konten terbaru
    # ikut terpasang. Aman — tidak menyentuh user/pengaturan/standar/metadata.
    info "Memperbarui dokumentasi (panduan + FAQ)..."
    docker compose run --rm migrate npx tsx prisma/seed-docs-only.ts \
      && ok "Dokumentasi diperbarui." || warn "Update dokumentasi dilewati."
  fi

  # 6. Start + tunggu ext-serv healthy
  info "Menjalankan ext-serv container..."
  docker compose up -d --no-deps ext-serv
  ok "ext-serv container started."
  info "Menunggu ext-serv healthy..."
  local ext_tries=0
  until docker compose exec -T ext-serv node -e "fetch('http://localhost:${PORT_EXT_SERV:-3007}/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" &>/dev/null; do
    ext_tries=$((ext_tries + 1))
    [[ $ext_tries -ge 20 ]] && { warn "ext-serv belum healthy setelah 40 detik — lanjutkan deploy."; break; }
    sleep 2
  done
  ok "ext-serv healthy."

  # 7. Build app (hanya jika build lokal)
  if [[ "${INSTALL_METHOD:-local}" == "local" ]]; then
    _build_compose "app" app || return 1
  fi

  # 8. Start app (tanpa nginx)
  info "Menjalankan app container..."
  docker compose up -d --no-deps app
  ok "App running."

  echo ""
  echo -e "  ${G}✓ Deploy lokal selesai!${NC}"
  echo -e "  ${W}  Akses aplikasi: ${C}http://localhost:${port}${NC}"
  echo -e "  ${DIM}  Untuk stop: docker compose stop app${NC}"
}

# ─── Port helpers ─────────────────────────────────────────────────────────────
# Array global; di-reset setiap kali fn_generate_env dipanggil
_CHOSEN_PORTS=()

# Kembalikan 0 jika port sedang dipakai proses di sistem, 1 jika bebas
_port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tlnp "sport = :${port}" 2>/dev/null | grep -q LISTEN && return 0
  fi
  if command -v netstat &>/dev/null; then
    netstat -tlnp 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" && return 0
  fi
  # Fallback bash built-in — bungkus timeout agar tidak hang jika port tidak listen
  if command -v timeout &>/dev/null; then
    timeout 1 bash -c "(: < /dev/tcp/127.0.0.1/${port})" 2>/dev/null && return 0
  else
    (: < "/dev/tcp/127.0.0.1/${port}") 2>/dev/null && return 0
  fi
  return 1
}

# Tanya port dengan validasi: angka valid, tidak duplikat, tidak bentrok di OS
# Hasil disimpan di _PORT_RESULT (hindari subshell agar _CHOSEN_PORTS bisa diupdate)
_PORT_RESULT=""
_ask_port() {
  local label="$1" default="$2"
  local port _force

  while true; do
    # Buang sisa input yang ter-buffer sebelum prompt
    while IFS= read -r -t 0 _discard 2>/dev/null; do :; done
    read -rp "  ${label} [${default}]: " port
    port="${port:-$default}"

    # Validasi: harus angka 1–65535
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo -e "  ${R}✗${NC} Bukan port valid (harus angka 1–65535). Coba lagi."
      continue
    fi

    # Cek duplikat dengan port yang sudah dipilih sebelumnya
    local dup_of=""
    if [[ ${#_CHOSEN_PORTS[@]} -gt 0 ]]; then
      local _ep _el
      for _entry in "${_CHOSEN_PORTS[@]}"; do
        _ep="${_entry%%:*}"; _el="${_entry#*:}"
        [[ "$port" == "$_ep" ]] && { dup_of="$_el"; break; }
      done
    fi
    if [[ -n "$dup_of" ]]; then
      echo -e "  ${R}✗${NC} Port ${W}${port}${NC} sudah dipilih untuk: ${Y}${dup_of}${NC}"
      echo    "     Pilih port lain."
      continue
    fi

    # Cek apakah port sedang dipakai di OS
    if _port_in_use "$port"; then
      echo -e "  ${Y}⚠${NC}  Port ${W}${port}${NC} sedang dipakai proses lain di sistem."
      read -rp "     Tetap gunakan port ${port}? (y/N): " _force
      if [[ "${_force,,}" == "y" ]]; then
        _CHOSEN_PORTS+=("${port}:${label}"); _PORT_RESULT="$port"; return
      fi
      continue
    fi

    _CHOSEN_PORTS+=("${port}:${label}"); _PORT_RESULT="$port"; return
  done
}

# ─── SSL chain validator ──────────────────────────────────────────────────────
# Periksa apakah SSL chain URL sudah lengkap (bisa diterima harvester CSW).
# Return 0 = valid / bukan https. Return 1 = chain tidak lengkap & user tolak perbaikan.
_validate_ssl_chain() {
  local url="$1"
  [[ "$url" != https://* ]] && return 0

  local host port
  host=$(echo "$url" | sed -E 's|https://([^/:]+).*|\1|')
  port=$(echo "$url" | sed -E 's|https://[^:]+:([0-9]+).*|\1|')
  [[ "$port" =~ ^[0-9]+$ ]] || port=443

  info "Memeriksa SSL chain untuk ${host}:${port}..."

  if ! command -v openssl &>/dev/null; then
    warn "openssl tidak ditemukan — validasi SSL dilewati."
    return 0
  fi

  local result verify_code verify_msg
  result=$(timeout 15 openssl s_client -connect "${host}:${port}" -servername "${host}" \
    -verify_return_error </dev/null 2>&1)
  verify_code=$(echo "$result" | awk '/Verify return code:/{print $4}')

  if [[ "$verify_code" == "0" ]]; then
    ok "SSL chain lengkap dan valid."
    return 0
  fi

  verify_msg=$(echo "$result" | grep "Verify return code:" | head -1)
  echo ""
  warn "SSL chain tidak lengkap atau tidak valid!"
  echo -e "  ${DIM}Detail: ${verify_msg}${NC}"
  echo ""
  echo -e "  ${Y}Harvester CSW (pycsw, GeoNode, dll.) akan menolak koneksi ke server ini${NC}"
  echo -e "  ${Y}jika SSL chain belum lengkap (intermediate CA tidak terpasang).${NC}"
  echo ""
  read -rp "  Mau kami bantu pasang SSL dengan chain CA yang lengkap (Let's Encrypt)? (y/N): " _ssl_fix
  if [[ "${_ssl_fix,,}" == "y" ]]; then
    fn_ssl_menu
    # Periksa ulang setelah setup SSL
    result=$(timeout 15 openssl s_client -connect "${host}:${port}" -servername "${host}" \
      -verify_return_error </dev/null 2>&1)
    verify_code=$(echo "$result" | awk '/Verify return code:/{print $4}')
    if [[ "$verify_code" == "0" ]]; then
      ok "SSL chain sekarang sudah valid. Melanjutkan setup..."
      return 0
    else
      warn "SSL chain masih belum valid setelah setup. Proses dihentikan."
      echo -e "  ${DIM}Periksa konfigurasi SSL Anda, lalu jalankan setup ulang.${NC}"
      return 1
    fi
  else
    echo ""
    warn "SSL chain tidak diperbaiki. Proses instalasi dihentikan."
    echo -e "  ${DIM}Perbaiki SSL Anda terlebih dahulu, lalu jalankan ulang setup .env.${NC}"
    echo -e "  ${DIM}Tip: pastikan server Nginx/Apache menyertakan intermediate CA di chain.${NC}"
    return 1
  fi
}

# ─── Validator input ──────────────────────────────────────────────────────────
# Format email dasar: harus ada @ dan domain dengan TLD minimal 2 karakter
_valid_email() {
  [[ "$1" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]
}

# Format URL: harus diawali http:// atau https://, diikuti host (domain/IP ± port)
_valid_url() {
  [[ "$1" =~ ^https?://[a-zA-Z0-9._\-]+(:[0-9]+)?(/.*)?$ ]]
}

# Nomor WA/HP — return 0 jika valid atau kosong (opsional)
# Pesan error disimpan di _PHONE_ERR
_PHONE_ERR=""
_valid_phone_wa() {
  local val="$1"
  _PHONE_ERR=""
  [[ -z "${val// /}" ]] && return 0          # kosong = OK (opsional)
  local digits="${val//[^0-9]/}"
  local norm="$digits"
  [[ "$digits" =~ ^0 ]] && norm="62${digits:1}"
  if (( ${#norm} < 7 )); then
    _PHONE_ERR="Nomor terlalu pendek (${#norm} digit). Gunakan minimal 7 digit, contoh: 081234567890"
    return 1
  fi
  if (( ${#norm} > 15 )); then
    _PHONE_ERR="Nomor terlalu panjang (${#norm} digit). Maksimal 15 digit."
    return 1
  fi
  # Deteksi prefix telepon kantor/PSTN Indonesia
  local -a LANDLINE=('6221' '6222' '6224' '6225' '6231' '6241' '6251' '6261' '6274' '6276' '6341' '6411')
  local p
  for p in "${LANDLINE[@]}"; do
    [[ "$norm" == "${p}"* ]] && {
      _PHONE_ERR="Terdeteksi nomor telepon kantor/PSTN. WhatsApp OTP tidak bisa dikirim ke nomor kantor — gunakan nomor HP (contoh: 081234567890)."
      return 1
    }
  done
  return 0
}

# ─── 9. Generate .env ────────────────────────────────────────────────────────
fn_generate_env() {
  echo -e "\n${W}  Generate Konfigurasi .env${NC}"
  echo "  ─────────────────────────────────────────────"

  # ── Cek file yang sudah ada ───────────────────────────────────────────────
  if [[ -f ".env" || -f "ext_serv-main/.env" ]]; then
    warn "File .env sudah ditemukan:"
    [[ -f ".env" ]]               && warn "  → .env"
    [[ -f "ext_serv-main/.env" ]] && warn "  → ext_serv-main/.env"
    echo ""
    read -rp "  Timpa dan buat ulang? (y/N): " _ov
    [[ "${_ov,,}" == "y" ]] || { warn "Dibatalkan."; return; }
  fi

  # ── Auto-generate dari Excel (jika file konfigurasi tersedia) ────────────
  local _excel_file=""
  for _ef in "config-instalasi.xlsx" "Config-Instalasi.xlsx" "KONFIGURASI.xlsx" "konfigurasi.xlsx"; do
    [[ -f "$_ef" ]] && { _excel_file="$_ef"; break; }
  done

  if [[ -n "$_excel_file" ]]; then
    echo ""
    echo -e "  ${G}✓${NC} File konfigurasi Excel ditemukan: ${W}${_excel_file}${NC}"
    if ! command -v python3 &>/dev/null; then
      warn "Python3 tidak tersedia — tidak bisa membaca Excel. Lanjutkan wizard manual."
    else
      if ! python3 -c "import openpyxl" 2>/dev/null; then
        warn "Modul openpyxl belum terinstal — mencoba instal otomatis..."
        local _oxl_ok=false
        # Coba pip3 / python3 -m pip, lalu dengan --break-system-packages (PEP 668),
        # lalu package manager distro sebagai fallback terakhir.
        pip3 install openpyxl -q 2>/dev/null && _oxl_ok=true
        [[ "$_oxl_ok" == false ]] && python3 -m pip install openpyxl -q 2>/dev/null && _oxl_ok=true
        [[ "$_oxl_ok" == false ]] && pip3 install openpyxl -q --break-system-packages 2>/dev/null && _oxl_ok=true
        [[ "$_oxl_ok" == false ]] && python3 -m pip install openpyxl -q --break-system-packages 2>/dev/null && _oxl_ok=true
        if [[ "$_oxl_ok" == false ]]; then
          if command -v apt-get &>/dev/null; then
            sudo apt-get install -y python3-openpyxl -qq 2>/dev/null && _oxl_ok=true
          elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3-openpyxl -q 2>/dev/null && _oxl_ok=true
          elif command -v yum &>/dev/null; then
            sudo yum install -y python3-openpyxl -q 2>/dev/null && _oxl_ok=true
          fi
        fi
        if [[ "$_oxl_ok" == true ]]; then
          ok "openpyxl berhasil diinstal."
        else
          warn "Gagal menginstal openpyxl. Lanjutkan wizard manual."
        fi
      fi
      if python3 -c "import openpyxl" 2>/dev/null; then
      echo -e "  ${DIM}Data isian akan dibaca dari Excel. Jawab pertanyaan pilihan berikut:${NC}"
      echo ""

      # ── 1. Posisi aplikasi (menentukan BASE_PATH) ─────────────────────────
      echo -e "  ${W}Posisi aplikasi di URL:${NC}"
      echo ""
      echo "  1) Server sudah punya geoportal"
      echo -e "     ${DIM}→ Aplikasi diakses di sub-path: /geomdb-hub${NC}"
      echo "  2) Server dedicated — aplikasi saja"
      echo -e "     ${DIM}→ Aplikasi diakses di root / (URL langsung)${NC}"
      echo "  3) Sub-direktori kustom"
      echo -e "     ${DIM}→ Sub-path tertentu, mis. /metadata (image harus sudah di-build via GitHub Actions)${NC}"
      echo ""
      read -rp "  Pilih [2]: " _v
      local _xl_geoportal="${_v:-2}"
      local _xl_custom_path="" _xl_custom_img=""
      if [[ "$_xl_geoportal" == "3" ]]; then
        while true; do
          read -rp "  Masukkan sub-path (awali dengan /, contoh: /metadata): " _bp
          if [[ "$_bp" =~ ^/[a-zA-Z0-9_/-]+$ ]]; then
            _xl_custom_path="$_bp"; break
          fi
          echo -e "  ${R}✗${NC} Sub-path harus diawali '/' dan hanya mengandung huruf, angka, '-', '_', '/'."
        done
        local _slug="${_xl_custom_path#/}"; _slug="${_slug//\//-}"
        _xl_custom_img="ghcr.io/harihk1/geomdb-hub-installer/app-${_slug}"
        warn "Pastikan image '${_xl_custom_img}' sudah di-build via 'Build custom basePath image' di GitHub Actions."
      fi

      # ── 2. Nginx ──────────────────────────────────────────────────────────
      echo ""
      echo -e "  ${W}┌─ Nginx ──────────────────────────────────────────────────────┐${NC}"
      echo -e "  ${DIM}• Pilih Y untuk produksi (HTTPS + domain publik).${NC}"
      echo -e "  ${DIM}• Pilih N untuk dev lokal saja.${NC}"
      local _xl_use_nginx="false" _xl_ext_nginx="false"
      read -rp "  Mau menggunakan Nginx? (y/N): " _v
      if [[ "${_v,,}" == "y" ]]; then
        _xl_use_nginx="true"
        echo -e "  ${DIM}Pilih N jika ingin Nginx dijalankan otomatis sebagai Docker container (rekomendasi).${NC}"
        echo -e "  ${DIM}Pilih Y jika server sudah punya Nginx sendiri di luar Docker.${NC}"
        read -rp "  Server sudah punya Nginx di luar Docker? (y/N): " _v
        if [[ "${_v,,}" == "y" ]]; then
          _xl_ext_nginx="true"
          warn "Mode Nginx eksternal — Docker Nginx dan Certbot tidak akan dijalankan."
          info "Arahkan Nginx Anda ke port app (Next.js) dan ext-serv sesuai yang dikonfigurasi di Excel."
        else
          info "Mode Nginx Docker — Nginx container akan dikelola oleh deploy.sh."
        fi
      else
        warn "Nginx dilewati — app dapat diakses langsung via port Next.js."
      fi

      # ── 3. WhatsApp OTP ───────────────────────────────────────────────────
      echo ""
      echo -e "  ${W}┌─ WhatsApp OTP ───────────────────────────────────────────────┐${NC}"
      echo -e "  ${Y}⚠  Jika DIAKTIFKAN: image lebih besar ~500MB (Chromium + whatsapp-web.js).${NC}"
      echo -e "  ${DIM}Fitur ini bisa diaktifkan nanti dengan generate ulang .env dan rebuild.${NC}"
      local _xl_wa="false"
      read -rp "  Aktifkan fitur WhatsApp OTP? (y/N): " _v
      [[ "${_v,,}" == "y" ]] && _xl_wa="true"

      # ── 4. Docker Network Geoportal (hanya jika geoportal) ────────────────
      local _xl_gnet=""
      if [[ "$_xl_geoportal" == "1" ]]; then
        echo ""
        echo -e "  ${W}┌─ Docker Network Geoportal ───────────────────────────────────┐${NC}"
        echo -e "  ${DIM}Nama network Docker tempat geoportal (GeoNode/ArcGIS) berjalan.${NC}"
        echo -e "  ${DIM}Diperlukan agar nginx geoportal bisa proxy ke geomdb_app.${NC}"
        local _all_nets=()
        if command -v docker &>/dev/null; then
          mapfile -t _all_nets < <(docker network ls --format "{{.Name}} {{.Driver}}" 2>/dev/null || true)
        fi
        if [[ ${#_all_nets[@]} -gt 0 ]]; then
          echo -e "  ${DIM}Network Docker yang tersedia:${NC}"
          local _ni
          for _ni in "${!_all_nets[@]}"; do
            printf "  %2d) %s\n" "$(( _ni + 1 ))" "${_all_nets[$_ni]}"
          done
          echo ""
          while true; do
            read -rp "  Nomor network geoportal: " _v
            if [[ -z "$_v" ]]; then
              echo -e "  ${R}✗${NC} Harus dipilih untuk mode geoportal."
              continue
            fi
            if ! [[ "$_v" =~ ^[0-9]+$ ]] || (( _v < 1 || _v > ${#_all_nets[@]} )); then
              echo -e "  ${R}✗${NC} Masukkan angka 1–${#_all_nets[@]}."
              continue
            fi
            _xl_gnet="${_all_nets[$(( _v - 1 ))]%% *}"
            echo -e "  ${G}✓${NC} Network dipilih: ${W}${_xl_gnet}${NC}"
            break
          done
        else
          echo -e "  ${DIM}Tidak ada network Docker terdeteksi. Ketik nama network secara manual.${NC}"
          while true; do
            read -rp "  Nama network geoportal: " _xl_gnet
            [[ -n "$_xl_gnet" ]] && break
            echo -e "  ${R}✗${NC} Nama network tidak boleh kosong untuk mode geoportal."
          done
        fi
      fi

      # ── Generate .env dari Excel + pilihan (script inline) ────────────────
      echo ""
      echo -e "  ${DIM}Membuat .env dari data Excel + pilihan di atas...${NC}"
      echo ""
      local _py_tmp
      _py_tmp=$(mktemp /tmp/geomdb_excel_XXXXXX.py)
      cat > "$_py_tmp" << 'GEOMDB_PY_EOF'
#!/usr/bin/env python3
import sys, os, re, secrets, base64
from datetime import datetime
try:
    import openpyxl
except ImportError:
    print("ERROR: modul openpyxl tidak terinstal. Jalankan: pip3 install openpyxl", file=sys.stderr)
    sys.exit(1)

G="\033[32m"; W="\033[1m"; Y="\033[33m"; C="\033[36m"; NC="\033[0m"; DIM="\033[2m"; R="\033[31m"
def err(m): print(f"\n  {R}✗{NC}  {m}", file=sys.stderr)
def ok(m):  print(f"  {G}✓{NC}  {m}")
def info(m):print(f"  {DIM}{m}{NC}")

def load_excel(path):
    try: wb = openpyxl.load_workbook(path, data_only=True)
    except Exception as e: err(f"Tidak bisa membuka file Excel: {e}"); sys.exit(1)
    ws = wb.active; cfg = {}
    for row in ws.iter_rows(min_row=2, values_only=True):
        if not row or not row[0]: continue
        key = str(row[0]).strip()
        if not key or key.startswith("#"): continue
        raw = row[2] if len(row) > 2 else None
        if raw is None or str(raw).strip() in ("", "None"): val = ""
        elif isinstance(raw, (int, float)): val = str(int(raw))
        else: val = str(raw).strip()
        cfg[key] = val
    return cfg

_RE_EMAIL  = re.compile(r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$")
_RE_URL    = re.compile(r"^https?://[a-zA-Z0-9._\-]+(:[0-9]+)?(/.*)?$")
_RE_ALPHA  = re.compile(r"^[a-zA-Z0-9_]+$")
_RE_SUBNET = re.compile(r"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$")

def validate(cfg):
    errs = []
    if not cfg.get("APP_URL"): errs.append("APP_URL (URL Publik Aplikasi) belum diisi.")
    elif not _RE_URL.match(cfg["APP_URL"]): errs.append(f"APP_URL tidak valid: '{cfg['APP_URL']}'")
    if not cfg.get("SEED_ADMIN_EMAIL"): errs.append("SEED_ADMIN_EMAIL (Email Administrator) belum diisi.")
    elif not _RE_EMAIL.match(cfg["SEED_ADMIN_EMAIL"]): errs.append(f"SEED_ADMIN_EMAIL tidak valid: '{cfg['SEED_ADMIN_EMAIL']}'")
    if not cfg.get("SEED_ADMIN_PASSWORD"): errs.append("SEED_ADMIN_PASSWORD (Password Administrator) belum diisi.")
    elif len(cfg["SEED_ADMIN_PASSWORD"]) < 8: errs.append("SEED_ADMIN_PASSWORD minimal 8 karakter.")
    mu = cfg.get("MINIO_USER","").strip() or "geomdb_minio"
    if not _RE_ALPHA.match(mu): errs.append(f"MINIO_USER tidak valid: '{mu}'")
    sn = cfg.get("GEOMDB_SUBNET","").strip() or "172.28.0.0/24"
    if not _RE_SUBNET.match(sn): errs.append(f"GEOMDB_SUBNET tidak valid: '{sn}' - format x.x.x.x/prefix, mis. 172.28.0.0/24.")
    else:
        pfx = int(sn.split("/")[1])
        if pfx < 8 or pfx > 30: errs.append(f"GEOMDB_SUBNET prefix /{pfx} tidak wajar - gunakan /16 hingga /28.")
        elif sn.split("/")[0] in ["172.17.0.0","172.18.0.0","172.19.0.0"]:
            sys.stdout.write(f"\n  {Y}!{NC}  GEOMDB_SUBNET {W}{sn}{NC} adalah subnet default Docker (bridge/host network).\n")
            sys.stdout.write(f"  {DIM}Mungkin sudah dipakai dan bisa konflik. Rekomendasi: 172.20-31.x.x/24.{NC}\n")
            sys.stdout.flush()
    import socket
    _PL = [("PORT_HTTP","HTTP Nginx","80"),("PORT_HTTPS","HTTPS Nginx","443"),
           ("PORT_APP","Aplikasi","3000"),("PORT_PG","PostgreSQL","5432"),
           ("PORT_REDIS","Redis","6379"),("PORT_MINIO_API","MinIO API","9000"),
           ("PORT_MINIO_CON","MinIO Console","9001"),("PORT_PYCSW","pycsw","8080"),
           ("PORT_EXT","ext-serv","3007")]
    use_ng = yn(cfg.get("_USE_NGINX"),True); ext_ng = yn(cfg.get("_EXT_NGINX"),False)
    skip_ng = (not use_ng) or ext_ng
    seen = {}
    for k,lbl,dfl in _PL:
        if k in ("PORT_HTTP","PORT_HTTPS") and skip_ng: continue
        raw = cfg.get(k,"").strip() or dfl
        if not (raw.isdigit() and 1 <= int(raw) <= 65535):
            errs.append(f"{k} ({lbl}) tidak valid: '{raw}' - harus angka 1-65535."); continue
        if raw in seen: errs.append(f"Konflik port: {k} ({lbl}) dan {seen[raw]} sama-sama menggunakan port {raw}.")
        else: seen[raw] = f"{k} ({lbl})"
    warns = []
    for ps,lbl in seen.items():
        try:
            s = socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.settimeout(0.3)
            if s.connect_ex(("127.0.0.1",int(ps)))==0: warns.append(f"  {Y}!{NC}  Port {W}{ps}{NC} ({lbl.split('(')[0].strip()}) sudah dipakai proses lain.")
            s.close()
        except Exception: pass
    if warns:
        print(); print(f"  {Y}Peringatan port yang sudah aktif:{NC}")
        for w in warns: sys.stdout.write(w+"\n")
        sys.stdout.write(f"  {DIM}Jika memang ingin menggunakan port tersebut, abaikan peringatan ini.{NC}\n")
        sys.stdout.flush()
    return errs

def yn(v, d=False):
    if not v: return d
    s = v.lower(); return s.startswith("y") or s in ("1","true")

def port(v, d):
    s = str(v).strip() if v else ""
    return s if s.isdigit() and 1 <= int(s) <= 65535 else d

def generate(cfg):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    app_url = cfg["APP_URL"].rstrip("/")
    geo = cfg.get("_GEOPORTAL","2").strip()
    if geo == "1":
        base_path = "/geomdb-hub"
    elif geo == "3":
        base_path = cfg.get("_CUSTOM_PATH","").strip()
    else:
        base_path = ""
    full_url  = app_url + base_path
    custom_img = cfg.get("_CUSTOM_APP_IMAGE","").strip()
    use_nginx = yn(cfg.get("_USE_NGINX"), True)
    ext_nginx = yn(cfg.get("_EXT_NGINX"), False)
    un_s = "true" if use_nginx else "false"
    en_s = "true" if ext_nginx else "false"
    p_http=port(cfg.get("PORT_HTTP"),"80"); p_https=port(cfg.get("PORT_HTTPS"),"443")
    p_app=port(cfg.get("PORT_APP"),"3000"); p_pg=port(cfg.get("PORT_PG"),"5432")
    p_redis=port(cfg.get("PORT_REDIS"),"6379"); p_minio=port(cfg.get("PORT_MINIO_API"),"9000")
    p_mcon=port(cfg.get("PORT_MINIO_CON"),"9001"); p_pycsw=port(cfg.get("PORT_PYCSW"),"8080")
    p_ext=port(cfg.get("PORT_EXT"),"3007")
    em=cfg["SEED_ADMIN_EMAIL"]; pw=cfg["SEED_ADMIN_PASSWORD"]
    nm=cfg.get("SEED_ADMIN_NAME","").strip() or "Administrator Sistem"
    org=cfg.get("SEED_ADMIN_ORG","").strip() or "Badan Informasi Geospasial"
    jb=cfg.get("SEED_ADMIN_JABATAN","").strip() or "System Administrator"
    tel=cfg.get("SEED_ADMIN_TELEPON","").strip()
    gnet=cfg.get("GEOPORTAL_NETWORK","").strip()
    arcgis_probe_domains=cfg.get("ARCGIS_PROBE_DOMAINS","go.id").strip() or "go.id"
    mu=cfg.get("MINIO_USER","").strip() or "geomdb_minio"
    sn=cfg.get("GEOMDB_SUBNET","").strip() or "172.28.0.0/24"
    wa=yn(cfg.get("_WA_ENABLED"),False); wa_s="true" if wa else "false"
    def csw(k,d=""): return cfg.get(k,"").strip() or d
    ct=csw("CSW_TITLE","Geomdb Hub CSW"); ca=csw("CSW_ABSTRACT","OGC Catalogue Service 2.0.2 - Katalog metadata geospasial")
    ck=csw("CSW_KEYWORDS","metadata,geospasial,JIGN,INA-SDI"); cp=csw("CSW_PROVIDER_NAME","Badan Informasi Geospasial")
    ccn=csw("CSW_CONTACT_NAME","Administrator"); ccp=csw("CSW_CONTACT_POSITION","System Administrator")
    cca=csw("CSW_CONTACT_ADDRESS"); ccc=csw("CSW_CONTACT_CITY","Jakarta")
    ccpv=csw("CSW_CONTACT_PROVINCE","DKI Jakarta"); ccpc=csw("CSW_CONTACT_POSTALCODE")
    ccph=csw("CSW_CONTACT_PHONE"); ccf=csw("CSW_CONTACT_FAX"); cce=csw("CSW_CONTACT_EMAIL")
    ccco=csw("CSW_CONTACT_COUNTRY","Indonesia"); ccu=csw("CSW_CONTACT_URL")
    cch=csw("CSW_CONTACT_HOURS","08:00-16:00"); cci=csw("CSW_CONTACT_INSTRUCTIONS","Senin-Jumat")
    ccr=csw("CSW_CONTACT_ROLE","Walidata")
    info("Membuat secrets...")
    pg_p=secrets.token_hex(24); rd_p=secrets.token_hex(24); mn_p=secrets.token_hex(24)
    jwt=secrets.token_hex(32); sec=secrets.token_hex(32); enc=secrets.token_hex(32)
    ip_s=secrets.token_hex(16); hk=secrets.token_hex(24); sk=secrets.token_hex(32)
    sa=""
    if os.path.isfile(".env"):
        for ln in open(".env","r",encoding="utf-8"):
            m=re.match(r'^NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=["\']?(.+?)["\']?\s*$',ln)
            if m: sa=m.group(1).strip(); break
    if not sa: sa=base64.b64encode(secrets.token_bytes(24)).decode()
    pl=[]
    if use_nginx and not ext_nginx: pl+=[f"PORT_HTTP={p_http}",f"PORT_HTTPS={p_https}"]
    pl+=[f"PORT_APP={p_app}",f"PORT_POSTGRES={p_pg}",f"PORT_REDIS={p_redis}",
         f"PORT_MINIO_API={p_minio}",f"PORT_MINIO_CONSOLE={p_mcon}",
         f"PORT_PYCSW={p_pycsw}",f"PORT_EXT_SERV={p_ext}"]
    pb="\n".join(pl)
    bpl=f"NEXT_PUBLIC_BASE_PATH={base_path}" if base_path else ""
    custom_img_line=f"GEOMDB_APP_IMAGE={custom_img}" if custom_img else ""
    tl=f"SEED_ADMIN_TELEPON={tel}" if tel else ""
    main_env=f"""# ════════════════════════════════════════════════════════════
#  Geomdb Hub — Environment Configuration
#  Di-generate oleh deploy.sh — {now}
# ════════════════════════════════════════════════════════════
#
#  Cara mengubah konfigurasi:
#  1. Edit file ini langsung:  nano .env  (atau vim / editor lain)
#  2. Restart container sesuai jenis perubahan:
#
#     Perubahan runtime (URL, secret, CSW, port, ext-serv):
#       docker compose up -d --force-recreate
#
#     Perubahan build-time (NEXT_PUBLIC_*, WA_ENABLED, BASE_PATH):
#       docker compose up -d --build app
#
#  ⚠  JANGAN ubah setelah data ada — akan merusak data yang tersimpan:
#     POSTGRES_PASSWORD · MINIO_ROOT_PASSWORD · REDIS_PASSWORD
#     ENCRYPTION_KEY · NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
# ════════════════════════════════════════════════════════════

# ─── Database ────────────────────────────────────────────────
# Untuk local dev (Next.js langsung, tanpa Docker):
DATABASE_URL="postgresql://geomdb:{pg_p}@localhost:{p_pg}/geomdb_hub"
# Di Docker, di-override otomatis oleh docker-compose.yml

# ─── Auth ────────────────────────────────────────────────────
JWT_SECRET="{jwt}"
APP_SECRET="{sec}"
# Kunci terpisah untuk enkripsi field sensitif (email, telepon) di DB.
# Pisah dari JWT_SECRET agar rotasi salah satu tidak merusak yang lain.
ENCRYPTION_KEY="{enc}"
# COOKIE_SECURE=false  # uncomment jika local dev via HTTP

# ─── Aplikasi ────────────────────────────────────────────────
NEXT_PUBLIC_APP_URL="{full_url}"
# APP_URL = URL absolut RUNTIME untuk link sisi-server (email/redirect/CSW/XML).
APP_URL="{full_url}"
# Kunci enkripsi Server Actions Next.js — HARUS STABIL antar-build.
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY="{sa}"
{bpl}
{custom_img_line}
WA_ENABLED={wa_s}
NEXT_PUBLIC_WA_ENABLED={wa_s}
NODE_ENV="production"
# Salt untuk hashing IP pada log view katalog (UU PDP compliance).
IP_SALT="{ip_s}"

# ─── Registry GHCR (opsional) ────────────────────────────────
# Isi jika ingin pakai image dari registry daripada build lokal.
# Kosongkan (hapus atau komen) untuk tetap build lokal.
# GEOMDB_APP_IMAGE=ghcr.io/harihk1/geomdb-hub/app-geoportal
# GEOMDB_MIGRATE_IMAGE=ghcr.io/harihk1/geomdb-hub/migrate
# GEOMDB_EXT_SERV_IMAGE=ghcr.io/harihk1/geomdb-hub/ext-serv
# GEOMDB_IMAGE_TAG=latest

# ─── Docker services ─────────────────────────────────────────
POSTGRES_PASSWORD="{pg_p}"
MINIO_ROOT_USER="{mu}"
MINIO_ROOT_PASSWORD="{mn_p}"

# ─── Redis ───────────────────────────────────────────────────
REDIS_PASSWORD="{rd_p}"
REDIS_URL="redis://:{rd_p}@localhost:{p_redis}"
# Di Docker: di-override ke redis://:password@redis:6379

# ─── MinIO ───────────────────────────────────────────────────
MINIO_URL="http://localhost:{p_minio}"
MINIO_ENDPOINT="localhost"
MINIO_PORT="{p_minio}"
MINIO_BUCKET="geomdb-hub"
# Di Docker: di-override ke http://minio:9000

# ─── pycsw ───────────────────────────────────────────────────
PYCSW_URL="http://localhost:{p_pycsw}"
NEXT_PUBLIC_PYCSW_URL="{full_url}/csw"
# Di Docker: di-override ke http://pycsw:8000
# Untuk production, NEXT_PUBLIC_PYCSW_URL harus URL yang bisa diakses browser.

# ─── CSW Identitas Layanan ────────────────────────────────────
# Dipakai oleh pycsw (via docker-compose env) saat container start.
# Bisa juga dikonfigurasi via menu admin → Pengaturan CSW.
CSW_TITLE="{ct}"
CSW_ABSTRACT="{ca}"
CSW_KEYWORDS="{ck}"
CSW_FEES=None
CSW_ACCESS_CONSTRAINTS=None
CSW_PROVIDER_NAME="{cp}"
CSW_CONTACT_NAME="{ccn}"
CSW_CONTACT_POSITION="{ccp}"
CSW_CONTACT_ADDRESS="{cca}"
CSW_CONTACT_CITY="{ccc}"
CSW_CONTACT_PROVINCE="{ccpv}"
CSW_CONTACT_POSTALCODE="{ccpc}"
CSW_CONTACT_PHONE="{ccph}"
CSW_CONTACT_FAX="{ccf}"
CSW_CONTACT_EMAIL="{cce}"
CSW_CONTACT_COUNTRY="{ccco}"
CSW_CONTACT_URL="{ccu}"
CSW_CONTACT_HOURS="{cch}"
CSW_CONTACT_INSTRUCTIONS="{cci}"
CSW_CONTACT_ROLE="{ccr}"

# ─── OAuth2 Docker networking ────────────────────────────────
# Agar server-side token exchange ke provider OAuth2 yang berjalan di host
# (mis. localhost) bisa diakses dari dalam container Docker.
DOCKER_INTERNAL_HOST=host.docker.internal

# ─── Geoportal integration (opsional) ────────────────────────
# Nama Docker network geoportal (GeoNode, ArcGIS Portal, dll.) agar
# nginx geoportal bisa proxy ke geomdb_app.
# Kosongkan jika geomdb tidak dijalankan bersama geoportal.
GEOPORTAL_NETWORK={gnet}

# ─── ext-serv (Email + WhatsApp API) ─────────────────────────
EXT_SERV_URL="http://localhost:{p_ext}"
EXT_SERV_API_KEY="{sk}"
# Di Docker: EXT_SERV_URL di-override ke http://ext-serv:3007

# ─── ArcGIS probe allowlist ───────────────────────────────────
# Domain yang diizinkan untuk probe ketersediaan service ArcGIS (publik, tanpa login).
# Pisahkan dengan koma. Subdomain otomatis diizinkan (go.id → *.go.id).
# Kosongkan untuk memblokir semua probe dari publik.
ARCGIS_PROBE_DOMAINS={arcgis_probe_domains}

# ─── Health check (monitoring) ───────────────────────────────
# Dipakai oleh tools monitoring (Uptime Kuma, Prometheus, dll.)
# sebagai Bearer token ke GET /api/health
HEALTH_API_KEY="{hk}"

# ─── GeoNode integration (opsional) ──────────────────────────
# Isi jika ingin sinkron metadata ke GeoNode. Bisa juga dikonfigurasi
# via menu admin → Pengaturan → GeoNode.
# GEONODE_URL=https://geonode.example.com
# GEONODE_CLIENT_ID=your_client_id
# GEONODE_CLIENT_SECRET=your_client_secret
# GEONODE_CSW_USER=admin
# GEONODE_CSW_PASSWORD=your_password

# ─── Network ─────────────────────────────────────────────────
# Subnet internal Docker untuk container geomdb. Pastikan tidak bentrok
# dengan jaringan lain di server (docker network ls / ip route).
# Subnet default Docker yang sering sudah terpakai: 172.17/18/19.0.0/16
# Cek subnet aktif: docker network inspect $(docker network ls -q) | grep Subnet
GEOMDB_SUBNET={sn}

# ─── Port overrides (docker-compose) ─────────────────────────
{pb}

# ─── WARP (Cloudflare WireGuard) ─────────────────────────────
# WARP diaktifkan otomatis jika koneksi ke host:port di bawah gagal (diblokir ISP).
# Ubah jika provider SMTP Anda bukan Gmail.
# WARP_CHECK_HOST=smtp.gmail.com
# WARP_CHECK_PORT=465

# ─── Nginx ───────────────────────────────────────────────────
# true  = Nginx dikelola di luar Docker (tidak perlu certbot/nginx container)
# false = Nginx dijalankan sebagai Docker container oleh deploy.sh
# Jika USE_NGINX=false, Nginx tidak digunakan sama sekali
USE_NGINX={un_s}
USE_EXTERNAL_NGINX={en_s}

# ─── Seed Admin (hanya dipakai saat seed pertama kali) ───────
SEED_ADMIN_EMAIL="{em}"
SEED_ADMIN_PASSWORD="{pw}"
SEED_ADMIN_NAME="{nm}"
SEED_ADMIN_ORG="{org}"
SEED_ADMIN_JABATAN="{jb}"
{tl}
"""
    ext_env=f"""# ext-serv — Environment Configuration
# Di-generate oleh deploy.sh — {now}
PORT=3007
NODE_ENV=production
ALLOWED_ORIGINS={app_url},http://localhost:{p_app}
API_SECRET_KEY={sk}
WA_ENABLED={wa_s}
WA_SESSION_DIR=./.wwebjs_auth
MAIL_TIMEOUT=10000
"""
    with open(".env","w",encoding="utf-8") as f: f.write(main_env)
    os.chmod(".env", 0o600)
    ok("Berhasil menulis .env (chmod 600)")
    os.makedirs("ext_serv-main",exist_ok=True)
    with open("ext_serv-main/.env","w",encoding="utf-8") as f: f.write(ext_env)
    os.chmod("ext_serv-main/.env", 0o600)
    ok("Berhasil menulis ext_serv-main/.env (chmod 600)")
    print()
    print(f"{Y}  ┌──────────────────────────────────────────────────────────────────┐")
    print(f"  │          SIMPAN CREDENTIAL BERIKUT DI TEMPAT AMAN !              │")
    print(f"  ├──────────────────────────────────────────────────────────────────┤")
    print(f"  │  {'Admin email:':<36} {em:<27} │")
    print(f"  │  {'Admin password:':<36} {pw:<27} │")
    print(f"  │  {'PostgreSQL password:':<36} {pg_p[:27]:<27} │")
    print(f"  │  {'MinIO password:':<36} {mn_p[:27]:<27} │")
    print(f"  │  {'Shared API Key:':<36} {sk[:24]+'...':<27} │")
    print(f"  └──────────────────────────────────────────────────────────────────┘{NC}")
    print(); print(f"  {W}URL Aplikasi:{NC} {C}{full_url}{NC}"); print()

def preview(cfg):
    geo=cfg.get("_GEOPORTAL","2").strip()
    app_url=cfg.get("APP_URL","").rstrip("/")
    if geo=="1": base_path="/geomdb-hub"
    elif geo=="3": base_path=cfg.get("_CUSTOM_PATH","").strip()
    else: base_path=""
    full_url=app_url+base_path
    use_ng=yn(cfg.get("_USE_NGINX"),True); ext_ng=yn(cfg.get("_EXT_NGINX"),False)
    wa_en=yn(cfg.get("_WA_ENABLED"),False)
    gnet=cfg.get("GEOPORTAL_NETWORK","").strip()
    em=cfg.get("SEED_ADMIN_EMAIL",""); pw=cfg.get("SEED_ADMIN_PASSWORD","")
    nm=cfg.get("SEED_ADMIN_NAME","").strip() or "Administrator Sistem"
    org=cfg.get("SEED_ADMIN_ORG","").strip() or "Badan Informasi Geospasial"
    jb=cfg.get("SEED_ADMIN_JABATAN","").strip() or "System Administrator"
    tel=cfg.get("SEED_ADMIN_TELEPON","").strip()
    mu=cfg.get("MINIO_USER","").strip() or "geomdb_minio"
    ph=port(cfg.get("PORT_HTTP"),"80"); phs=port(cfg.get("PORT_HTTPS"),"443")
    pa=port(cfg.get("PORT_APP"),"3000"); ppg=port(cfg.get("PORT_PG"),"5432")
    prd=port(cfg.get("PORT_REDIS"),"6379"); pmn=port(cfg.get("PORT_MINIO_API"),"9000")
    pmc=port(cfg.get("PORT_MINIO_CON"),"9001"); pcs=port(cfg.get("PORT_PYCSW"),"8080")
    pex=port(cfg.get("PORT_EXT"),"3007")
    def csw2(k,d=""): return cfg.get(k,"").strip() or d
    ct=csw2("CSW_TITLE","Geomdb Hub CSW"); cp=csw2("CSW_PROVIDER_NAME","Badan Informasi Geospasial")
    ccn=csw2("CSW_CONTACT_NAME","Administrator")
    ccc=csw2("CSW_CONTACT_CITY","Jakarta"); ccpv=csw2("CSW_CONTACT_PROVINCE","DKI Jakarta")
    cce=csw2("CSW_CONTACT_EMAIL")
    ng_mode=("Docker container (dikelola deploy.sh)" if use_ng and not ext_ng
             else "Eksternal (Nginx di luar Docker)" if use_ng
             else "Tidak digunakan (akses langsung via port)")
    wa_lbl="Aktif (+Chromium, build besar)" if wa_en else "Nonaktif (skip Chromium)"
    LB=28; VW=37
    def row(lbl,val): print(f"  │  {lbl:<{LB}} {str(val)[:VW]:<{VW}}│")
    def sep(): print("  ├──────────────────────────────────────────────────────────────────┤")
    print()
    print(f"{W}  ┌──────────────────────────────────────────────────────────────────┐")
    print(f"  │          PRATINJAU KONFIGURASI — PERIKSA SEBELUM LANJUT         │{NC}")
    sep()
    row("URL Publik (lengkap):",full_url); row("Sub-path:",base_path or "(root /)")
    sep()
    row("Email admin:",em); row("Password admin:",pw)
    row("Nama admin:",nm); row("Organisasi:",org); row("Jabatan:",jb)
    if tel: row("No. WhatsApp:",tel)
    sep()
    row("Nginx:",ng_mode)
    if use_ng and not ext_ng: row("Port HTTP/HTTPS:",f"{ph} / {phs}")
    row("Port App:",pa); row("Port PostgreSQL:",ppg)
    row("Port Redis:",prd); row("Port MinIO API:",pmn)
    row("Port MinIO Console:",pmc); row("Port pycsw:",pcs)
    row("Port ext-serv:",pex)
    sep(); row("MinIO root user:",mu)
    sep(); row("WhatsApp OTP:",wa_lbl)
    if gnet: row("Geoportal Network:",gnet)
    sep()
    row("CSW Judul:",ct); row("CSW Penyedia:",cp)
    row("CSW Kontak:",f"{ccn} / {cce or chr(8212)}"); row("CSW Kota:",f"{ccc}, {ccpv}")
    print("  └──────────────────────────────────────────────────────────────────┘")
    print()
    print(f"  {Y}Password admin diambil dari Excel. Secret lain (DB, Redis, MinIO) di-generate otomatis.{NC}")
    print()
    ans=input("  Semua isian sudah benar? Lanjutkan generate .env? (y/N): ").strip().lower()
    if ans!="y":
        print(f"\n  {Y}Dibatalkan.{NC} Perbaiki file Excel dan jalankan ulang menu 9.\n")
        sys.exit(2)

if len(sys.argv)<2: err("Usage: script.py <xlsx> [geoportal] [nginx] [ext_nginx] [wa] [gnet]"); sys.exit(1)
xlsx=sys.argv[1]
if not os.path.isfile(xlsx): err(f"File tidak ditemukan: {xlsx}"); sys.exit(1)
geo=sys.argv[2] if len(sys.argv)>2 else "2"
un =sys.argv[3] if len(sys.argv)>3 else "true"
en =sys.argv[4] if len(sys.argv)>4 else "false"
wa =sys.argv[5] if len(sys.argv)>5 else "false"
gnet_arg=sys.argv[6] if len(sys.argv)>6 else None
custom_path_arg=sys.argv[7] if len(sys.argv)>7 else None
custom_img_arg=sys.argv[8] if len(sys.argv)>8 else None
print(); info(f"Membaca konfigurasi dari: {xlsx}")
cfg=load_excel(xlsx)
cfg["_GEOPORTAL"]=geo; cfg["_USE_NGINX"]=un; cfg["_EXT_NGINX"]=en; cfg["_WA_ENABLED"]=wa
# GEOPORTAL_NETWORK diambil dari terminal (argv[6]), bukan Excel — agar bisa deteksi network live
if gnet_arg is not None: cfg["GEOPORTAL_NETWORK"]=gnet_arg
if custom_path_arg: cfg["_CUSTOM_PATH"]=custom_path_arg
if custom_img_arg:  cfg["_CUSTOM_APP_IMAGE"]=custom_img_arg
errs=validate(cfg)
if errs:
    print(); print(f"  {R}✗  Konfigurasi Excel belum lengkap:{NC}")
    for e in errs: print(f"     {Y}•{NC} {e}")
    print(); print(f"  {DIM}Buka file Excel, lengkapi kolom NILAI yang bertanda ★ Wajib, lalu simpan dan coba lagi.{NC}")
    sys.exit(1)
preview(cfg)
generate(cfg)
GEOMDB_PY_EOF
      python3 "$_py_tmp" "$_excel_file" "$_xl_geoportal" "$_xl_use_nginx" "$_xl_ext_nginx" "$_xl_wa" "$_xl_gnet" "$_xl_custom_path" "$_xl_custom_img"
      _py_rc=$?
      rm -f "$_py_tmp"
      if [[ $_py_rc -eq 0 ]]; then
        ok "File .env berhasil di-generate!"
        echo ""
        echo -e "  ${DIM}Langkah selanjutnya:${NC}"
        echo -e "  ${DIM}  • Deploy server → menu 4 (lalu atur SSL di menu 8)${NC}"
        return
      elif [[ $_py_rc -eq 2 ]]; then
        warn "Generate .env dibatalkan."
        return
      else
        echo ""
        warn "Gagal membaca konfigurasi Excel."
        echo -e "  ${DIM}Periksa isian kolom NILAI di file Excel (field ★ Wajib harus terisi).${NC}"
        echo -e "  ${DIM}Lanjutkan dengan wizard manual, atau perbaiki Excel dan jalankan ulang menu 9.${NC}"
      fi
      fi
    fi
    echo ""
  fi

  echo ""
  echo -e "  ${C}Tekan Enter untuk memakai nilai default [ dalam kurung ].${NC}"

  # ── Aplikasi ──────────────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ Aplikasi ──────────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Origin (scheme + domain/IP + port) tempat aplikasi diakses dari browser.${NC}"
  echo -e "  ${DIM}JANGAN sertakan sub-path di sini — sub-path ditanya terpisah di bawah.${NC}"
  echo -e "  ${DIM}Dipakai untuk: OAuth2 redirect URI, link email, konfigurasi CORS.${NC}"
  echo -e "  ${DIM}Contoh production: https://metadata.instansi.go.id${NC}"
  echo -e "  ${DIM}Contoh lokal     : http://localhost${NC}"
  local _url APP_URL
  while true; do
    read -rp "  Origin URL publik aplikasi [http://localhost:3000]: " _url
    APP_URL="${_url:-http://localhost:3000}"
    if ! _valid_url "$APP_URL"; then
      echo -e "  ${R}✗${NC} Format URL tidak valid. Harus diawali ${W}http://${NC} atau ${W}https://${NC}, diikuti domain atau IP."
      echo -e "     Contoh: ${W}https://metadata.instansi.go.id${NC}  atau  ${W}http://192.168.1.10:3000${NC}"
      continue
    fi
    break
  done
  local _v  # variabel temp untuk semua read berikutnya

  echo ""
  echo -e "  ${W}Posisi aplikasi di URL:${NC}"
  echo ""
  echo "  1) Server sudah punya geoportal"
  echo -e "     ${DIM}→ Aplikasi diakses di: ${APP_URL}/geomdb-hub${NC}"
  echo "  2) Server dedicated — aplikasi saja"
  echo -e "     ${DIM}→ Aplikasi diakses di: ${APP_URL} (root /)${NC}"
  echo "  3) Sub-direktori kustom"
  echo -e "     ${DIM}→ Aplikasi diakses di sub-path tertentu (mis. /metadata)${NC}"
  echo -e "     ${DIM}  Syarat: image custom sudah di-build via GitHub Actions terlebih dahulu.${NC}"
  echo ""
  read -rp "  Pilih [2]: " _v
  local BASE_PATH="" CUSTOM_APP_IMAGE=""
  case "${_v:-2}" in
    1) BASE_PATH="/geomdb-hub" ;;
    3)
      while true; do
        read -rp "  Masukkan sub-path (awali dengan /, contoh: /metadata): " _bp
        if [[ "$_bp" =~ ^/[a-zA-Z0-9_/-]+$ ]]; then
          BASE_PATH="$_bp"
          break
        fi
        echo -e "  ${R}✗${NC} Sub-path harus diawali '/' dan hanya mengandung huruf, angka, '-', '_', '/'."
      done
      local _img_slug="${BASE_PATH#/}"
      _img_slug="${_img_slug//\//-}"
      CUSTOM_APP_IMAGE="ghcr.io/harihk1/geomdb-hub-installer/app-${_img_slug}"
      warn "Pastikan image '${CUSTOM_APP_IMAGE}' sudah di-build via workflow 'Build custom basePath image' di GitHub Actions."
      ;;
  esac
  # URL lengkap = origin + sub-path (dipakai sebagai NEXT_PUBLIC_APP_URL)
  local FULL_APP_URL="${APP_URL}${BASE_PATH}"

  # ── Akun Admin (seed pertama kali) ────────────────────────────────────────
  echo -e "\n  ${W}┌─ Akun Admin (dibuat saat seed database pertama kali) ──────┐${NC}"
  echo -e "  ${DIM}Akun ini hanya dibuat SEKALI saat database pertama kali diisi.${NC}"
  echo -e "  ${DIM}Simpan email dan password ini — digunakan untuk login pertama.${NC}"
  local SEED_ADMIN_EMAIL SEED_ADMIN_PASSWORD SEED_ADMIN_NAME SEED_ADMIN_ORG SEED_ADMIN_JABATAN SEED_ADMIN_TELEPON
  echo -e "  ${Y}⚠  Gunakan email yang benar-benar bisa Anda akses sekarang!${NC}"
  echo -e "  ${DIM}Kode OTP akan dikirim ke email ini setiap kali login — jika email salah${NC}"
  echo -e "  ${DIM}atau tidak bisa diakses, Anda tidak akan bisa masuk ke aplikasi.${NC}"
  while true; do
    read -rp "  Email admin                              : " SEED_ADMIN_EMAIL
    if [[ -z "$SEED_ADMIN_EMAIL" ]]; then
      echo -e "  ${R}✗${NC} Email tidak boleh kosong."
      continue
    fi
    if ! _valid_email "$SEED_ADMIN_EMAIL"; then
      echo -e "  ${R}✗${NC} Format email tidak valid. Contoh: ${W}admin@instansi.go.id${NC}"
      continue
    fi
    break
  done
  echo -e "  ${DIM}Password untuk login. Minimal 8 karakter. Tidak akan ditampilkan.${NC}"
  while true; do
    read -rsp "  Password admin (min 8 karakter, tidak tampil): " SEED_ADMIN_PASSWORD; echo
    [[ ${#SEED_ADMIN_PASSWORD} -ge 8 ]] && break
    echo -e "  ${R}✗${NC} Password minimal 8 karakter."
  done
  echo -e "  ${DIM}Nama yang tampil di profil dan email notifikasi.${NC}"
  read -rp "  Nama lengkap admin              [Administrator Sistem]: " _v
  SEED_ADMIN_NAME="${_v:-Administrator Sistem}"
  echo -e "  ${DIM}Nama instansi/organisasi. Tampil di profil dan header sistem.${NC}"
  echo -e "  ${DIM}Contoh: Pemerintah Provinsi Jawa Barat${NC}"
  echo -e "  ${DIM}        Pemerintah Kabupaten Bogor${NC}"
  echo -e "  ${DIM}        Kementerian Lingkungan Hidup dan Kehutanan${NC}"
  echo -e "  ${DIM}        Badan Informasi Geospasial${NC}"
  read -rp "  Organisasi admin                [Badan Informasi Geospasial]     : " _v
  SEED_ADMIN_ORG="${_v:-Badan Informasi Geospasial}"
  echo -e "  ${DIM}Jabatan/posisi admin di organisasi.${NC}"
  read -rp "  Jabatan admin                   [System Administrator]: " _v
  SEED_ADMIN_JABATAN="${_v:-System Administrator}"
  echo -e "  ${Y}⚠  Gunakan nomor HP (bukan telepon kantor) yang aktif dan bisa Anda akses!${NC}"
  echo -e "  ${DIM}Kode OTP akan dikirim via WhatsApp ke nomor ini jika fitur WA diaktifkan.${NC}"
  echo -e "  ${DIM}Format yang diterima:${NC}"
  echo -e "  ${DIM}  • 08xxxxxxxxxx   → contoh: 081234567890   (HP Indonesia diawali 0)${NC}"
  echo -e "  ${DIM}  • 628xxxxxxxxxx  → contoh: 6281234567890  (format internasional)${NC}"
  echo -e "  ${Y}  ✗ Nomor telepon kantor (021-xxx, 022-xxx, dll.) TIDAK bisa menerima WA${NC}"
  echo -e "  ${DIM}Kosongkan jika tidak ingin menggunakan OTP via WhatsApp.${NC}"
  while true; do
    read -rp "  No. WhatsApp admin (opsional, contoh: 081234567890): " SEED_ADMIN_TELEPON
    if ! _valid_phone_wa "$SEED_ADMIN_TELEPON"; then
      echo -e "  ${R}✗${NC} ${_PHONE_ERR}"
      continue
    fi
    break
  done

  # ── Validasi SSL chain (hanya jika https) ────────────────────────────────
  if ! _validate_ssl_chain "$APP_URL"; then
    return 1
  fi

  # ── Nginx ────────────────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ Nginx ─────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Nginx berfungsi sebagai reverse proxy: menerima request dari browser,${NC}"
  echo -e "  ${DIM}meneruskan ke app, dan menangani SSL/HTTPS.${NC}"
  echo -e "  ${DIM}• Pilih Y jika ingin HTTPS atau domain publik.${NC}"
  echo -e "  ${DIM}• Pilih N jika hanya untuk dev lokal atau sudah memiliki reverse proxy (akses langsung via port).${NC}"
  local use_nginx="false" ext_nginx="false"
  read -rp "  Mau menggunakan Nginx? (y/N): " _v
  if [[ "${_v,,}" == "y" ]]; then
    use_nginx="true"
    echo -e "  ${DIM}Jika server sudah punya Nginx sendiri (bukan Docker), pilih Y.${NC}"
    echo -e "  ${DIM}Deploy.sh tidak akan menjalankan Nginx container — konfigurasi di luar Docker.${NC}"
    echo -e "  ${DIM}Pilih N jika ingin Nginx dijalankan otomatis sebagai Docker container.${NC}"
    read -rp "  Server sudah punya Nginx di luar Docker? (y/N): " _v
    if [[ "${_v,,}" == "y" ]]; then
      ext_nginx="true"
      warn "Mode Nginx eksternal — Docker Nginx dan Certbot tidak akan dijalankan."
      info "Arahkan Nginx Anda ke port ${C}app (Next.js)${NC} dan port ${C}ext-serv${NC} sesuai yang dipilih nanti."
    else
      info "Mode Nginx Docker — Nginx container akan dikelola oleh deploy.sh."
    fi
  else
    warn "Nginx dilewati — app dapat diakses langsung via port Next.js yang dipilih."
  fi

  # ── Port ─────────────────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ Port ──────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Setiap port dicek otomatis: tidak boleh duplikat & tidak sedang dipakai.${NC}"
  echo -e "  ${DIM}Ubah hanya jika port default sudah digunakan proses lain di server.${NC}"
  _CHOSEN_PORTS=()

  local P_HTTP="" P_HTTPS=""
  if [[ "$use_nginx" == "true" && "$ext_nginx" == "false" ]]; then
    echo -e "  ${DIM}Port 80/443 harus terbuka di firewall untuk Nginx menerima request dari internet.${NC}"
    _ask_port "Port HTTP  (Nginx — akses publik)     " "80";  P_HTTP="$_PORT_RESULT"
    _ask_port "Port HTTPS (Nginx — akses publik SSL) " "443"; P_HTTPS="$_PORT_RESULT"
  fi
  echo -e "  ${DIM}Port internal Next.js. Jika pakai Nginx, port ini tidak perlu buka di firewall.${NC}"
  _ask_port "Port Next.js app                      " "3000"; local P_APP="$_PORT_RESULT"
  echo -e "  ${DIM}Port database PostgreSQL. Hanya diakses internal Docker — tidak perlu buka di firewall.${NC}"
  _ask_port "Port PostgreSQL                       " "5432"; local P_PG="$_PORT_RESULT"
  echo -e "  ${DIM}Port Redis (session & cache). Hanya diakses internal Docker.${NC}"
  _ask_port "Port Redis                            " "6379"; local P_REDIS="$_PORT_RESULT"
  echo -e "  ${DIM}Port MinIO API (penyimpanan file/upload). Diakses internal Docker.${NC}"
  _ask_port "Port MinIO API                        " "9000"; local P_MINIO="$_PORT_RESULT"
  echo -e "  ${DIM}Port MinIO Console (web UI admin MinIO). Akses via browser: http://server:port${NC}"
  _ask_port "Port MinIO Console                    " "9001"; local P_MINIO_CON="$_PORT_RESULT"
  echo -e "  ${DIM}Port pycsw (standar OGC CSW 2.0.2 untuk harvesting metadata geospasial).${NC}"
  _ask_port "Port pycsw (CSW endpoint)             " "8080"; local P_PYCSW="$_PORT_RESULT"
  echo -e "  ${DIM}Port ext-serv (layanan email & WhatsApp). Diakses internal Docker.${NC}"
  _ask_port "Port ext-serv (email+WA API)          " "3007"; local P_EXT="$_PORT_RESULT"

  # ── Docker Network — auto-detect ──────────────────────────────────────────
  echo -e "\n  ${W}┌─ Docker Network ────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Mendeteksi subnet dan network yang sudah dipakai...${NC}"

  # Auto-detect subnet bebas
  local GEOMDB_SUBNET
  GEOMDB_SUBNET="$(_find_free_subnet)"
  echo -e "  ${G}✓${NC} Subnet otomatis  : ${W}${GEOMDB_SUBNET}${NC}  ${DIM}(tidak bentrok dengan network yang ada)${NC}"
  echo -e "  ${DIM}  Untuk mengubah, edit GEOMDB_SUBNET di .env setelah selesai generate.${NC}"

  # Tampilkan semua network dengan nomor urut
  local _all_networks=()
  if command -v docker &>/dev/null; then
    mapfile -t _all_networks < <(docker network ls --format "{{.Name}} {{.Driver}}" 2>/dev/null || true)
  fi

  echo ""
  echo -e "  ${W}Network Docker di sistem ini:${NC}"
  echo -e "  ${DIM}  ─────────────────────────────────────────${NC}"
  if [[ ${#_all_networks[@]} -gt 0 ]]; then
    local _i
    for _i in "${!_all_networks[@]}"; do
      local _name="${_all_networks[$_i]%% *}"
      local _driver="${_all_networks[$_i]##* }"
      printf "    ${DIM}%2d)${NC}  ${C}%-30s${NC}  ${DIM}(%s)${NC}\n" "$(( _i + 1 ))" "$_name" "$_driver"
    done
  else
    echo -e "  ${Y}  (tidak bisa query Docker)${NC}"
  fi
  echo -e "  ${DIM}  ─────────────────────────────────────────${NC}"

  # Pilih network geoportal via nomor urut
  local GEOPORTAL_NETWORK=""
  echo ""
  echo -e "  ${DIM}Ketik nomor network geoportal di atas — agar nginx geoportal bisa${NC}"
  echo -e "  ${DIM}proxy ke geomdb_app. Tekan Enter jika geomdb berdiri sendiri (standalone).${NC}"
  while true; do
    read -rp "  Nomor network geoportal (Enter = standalone): " _v
    [[ -z "$_v" ]] && { GEOPORTAL_NETWORK=""; break; }
    if ! [[ "$_v" =~ ^[0-9]+$ ]] || (( _v < 1 || _v > ${#_all_networks[@]} )); then
      echo -e "  ${R}✗${NC} Masukkan angka 1–${#_all_networks[@]}, atau tekan Enter untuk standalone."
      continue
    fi
    GEOPORTAL_NETWORK="${_all_networks[$(( _v - 1 ))]%% *}"
    echo -e "  ${G}✓${NC} Network dipilih: ${W}${GEOPORTAL_NETWORK}${NC}"
    break
  done

  # Tampilkan ringkasan port yang dipilih
  echo -e "\n  ${G}✓${NC} Port yang akan digunakan:"
  if [[ -n "$P_HTTP" ]]; then
    printf "    HTTP %-5s  HTTPS %-5s  App %-5s  PG %-5s\n" \
      "$P_HTTP" "$P_HTTPS" "$P_APP" "$P_PG"
  else
    printf "    App %-5s  PG %-5s\n" "$P_APP" "$P_PG"
  fi
  printf "    Redis %-4s  MinIO %-4s  MinIO-Con %-4s  pycsw %-4s  ext-serv %-4s\n" \
    "$P_REDIS" "$P_MINIO" "$P_MINIO_CON" "$P_PYCSW" "$P_EXT"

  # ── MinIO ─────────────────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ MinIO ─────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}MinIO adalah object storage (seperti AWS S3) untuk menyimpan file upload,${NC}"
  echo -e "  ${DIM}thumbnail, dan dokumen. Password-nya di-generate otomatis (aman).${NC}"
  echo -e "  ${DIM}Hanya huruf, angka, dan underscore. Tidak boleh ada spasi.${NC}"
  local MINIO_USER
  while true; do
    read -rp "  MinIO root user                       [geomdb_minio]: " _v
    MINIO_USER="${_v:-geomdb_minio}"
    if ! [[ "$MINIO_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo -e "  ${R}✗${NC} Hanya huruf, angka, dan underscore yang diizinkan. Contoh: ${W}geomdb_minio${NC}"
      continue
    fi
    break
  done

  echo -e "\n  ${W}┌─ Email (SMTP) ───────────────────────────────────────────────┐${NC}"
  echo -e "  ${G}ℹ  Konfigurasi SMTP dilakukan via dashboard admin setelah deploy.${NC}"
  echo -e "  ${DIM}Buka: Pengaturan Org → Email (SMTP) → Konfigurasi${NC}"
  echo -e "  ${DIM}Tidak perlu mengisi SMTP di sini — data disimpan di database.${NC}"

  # ── ext-serv Dashboard ────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ Dashboard ext-serv (/ui) ───────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Dashboard web untuk memantau status WhatsApp, log email, dan uji kirim notifikasi.${NC}"
  echo -e "  ${DIM}Diakses di: http://server:${P_EXT}/ui — hanya untuk admin teknis.${NC}"
  echo -e "  ${DIM}Password dikosongkan = di-generate otomatis (aman, ditampilkan di akhir setup).${NC}"
  echo -e "  ${DIM}Hanya huruf, angka, underscore, dan tanda hubung. Tidak boleh ada spasi.${NC}"
  local UI_USER
  while true; do
    read -rp "  Username login dashboard              [admin]: " _v
    UI_USER="${_v:-admin}"
    if ! [[ "$UI_USER" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
      echo -e "  ${R}✗${NC} Hanya huruf, angka, ${W}_${NC} dan ${W}-${NC} yang diizinkan. Contoh: ${W}admin${NC}"
      continue
    fi
    break
  done
  read -rp "  Password login (kosong = generate otomatis)  : " UI_PASS
  echo -e "  ${DIM}Swagger UI berisi dokumentasi & uji coba API ext-serv secara interaktif.${NC}"
  echo -e "  ${DIM}Diakses di: http://server:${P_EXT}/api-docs${NC}"
  local SWAGGER_USER
  while true; do
    read -rp "  Swagger UI username                   [admin]: " _v
    SWAGGER_USER="${_v:-admin}"
    if ! [[ "$SWAGGER_USER" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
      echo -e "  ${R}✗${NC} Hanya huruf, angka, ${W}_${NC} dan ${W}-${NC} yang diizinkan. Contoh: ${W}admin${NC}"
      continue
    fi
    break
  done

  # ── WhatsApp OTP ──────────────────────────────────────────────────────────
  echo -e "\n  ${W}┌─ WhatsApp OTP ───────────────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Fitur WA mengirim kode OTP via pesan WhatsApp sebagai alternatif email.${NC}"
  echo -e "  ${DIM}Membutuhkan nomor WA aktif yang di-scan di dashboard ext-serv setelah deploy.${NC}"
  echo -e "  ${Y}⚠  Jika DIAKTIFKAN: build menyertakan Chromium & whatsapp-web.js${NC}"
  echo -e "  ${Y}   → ukuran image lebih besar ~500MB, build lebih lama.${NC}"
  echo -e "  ${DIM}Jika TIDAK diaktifkan: Chromium tidak diinstal, image lebih kecil & cepat.${NC}"
  echo -e "  ${DIM}Fitur ini bisa diaktifkan nanti dengan generate ulang .env dan rebuild.${NC}"
  local wa_enabled="false"
  read -rp "  Aktifkan fitur WhatsApp OTP? (y/N): " _v
  [[ "${_v,,}" == "y" ]] && wa_enabled="true"

  # ── ArcGIS probe allowlist ────────────────────────────────────────────────
  echo ""
  echo -e "  ${W}Domain ArcGIS yang boleh diprobe tanpa login (publik):${NC}"
  echo -e "  ${DIM}Pengguna publik dapat memeriksa ketersediaan service ArcGIS dari domain ini.${NC}"
  echo -e "  ${DIM}Pisahkan dengan koma. Subdomain otomatis diizinkan (go.id → *.go.id).${NC}"
  echo -e "  ${DIM}Kosongkan untuk memblokir semua probe dari publik.${NC}"
  read -rp "  Domain ArcGIS [go.id]: " _v
  local ARCGIS_PROBE_DOMAINS="${_v:-go.id}"

  # ── CSW / Identitas Layanan Metadata ─────────────────────────────────────
  echo -e "\n  ${W}┌─ Identitas Layanan CSW ──────────────────────────────────────┐${NC}"
  echo -e "  ${DIM}Nilai ini muncul di respons GetCapabilities CSW (built-in & pycsw).${NC}"
  echo -e "  ${DIM}Setelah deploy, built-in CSW juga bisa diubah via menu admin → Pengaturan CSW.${NC}"
  echo -e "  ${DIM}Untuk pycsw: nilai di .env hanya berlaku saat container (re)start.${NC}"
  read -rp "  Judul layanan CSW          [Geomdb Hub CSW]: " _v
  local CSW_TITLE="${_v:-Geomdb Hub CSW}"
  read -rp "  Abstrak layanan CSW                             : " _v
  local CSW_ABSTRACT="${_v:-OGC Catalogue Service 2.0.2 - Katalog metadata geospasial}"
  echo -e "  ${DIM}Pisahkan kata kunci dengan koma, tanpa spasi di awal/akhir.${NC}"
  read -rp "  Kata kunci CSW             [metadata,geospasial,JIGN,INA-SDI]: " _v
  local CSW_KEYWORDS="${_v:-metadata,geospasial,JIGN,INA-SDI}"
  local CSW_FEES="None"
  local CSW_ACCESS_CONSTRAINTS="None"
  read -rp "  Nama organisasi penyedia   [Badan Informasi Geospasial]: " _v
  local CSW_PROVIDER_NAME="${_v:-Badan Informasi Geospasial}"
  read -rp "  Nama kontak                [Administrator]: " _v
  local CSW_CONTACT_NAME="${_v:-Administrator}"
  read -rp "  Jabatan kontak             [System Administrator]: " _v
  local CSW_CONTACT_POSITION="${_v:-System Administrator}"
  read -rp "  Alamat kantor                               [  ]: " _v
  local CSW_CONTACT_ADDRESS="${_v:-}"
  read -rp "  Kota                       [Jakarta]: " _v
  local CSW_CONTACT_CITY="${_v:-Jakarta}"
  read -rp "  Provinsi                   [DKI Jakarta]: " _v
  local CSW_CONTACT_PROVINCE="${_v:-DKI Jakarta}"
  local CSW_CONTACT_POSTALCODE
  while true; do
    read -rp "  Kode pos (opsional, hanya angka)            [  ]: " _v
    CSW_CONTACT_POSTALCODE="${_v:-}"
    [[ -z "$CSW_CONTACT_POSTALCODE" ]] && break
    if ! [[ "$CSW_CONTACT_POSTALCODE" =~ ^[0-9]+$ ]]; then
      echo -e "  ${R}✗${NC} Kode pos hanya boleh angka. Contoh: ${W}16111${NC}"
      continue
    fi
    break
  done
  echo -e "  ${DIM}Hanya angka (0-9). Contoh: ${W}0211234567${DIM} atau ${W}622112345678${NC}"
  local CSW_CONTACT_PHONE
  while true; do
    read -rp "  Telepon (opsional)                          [  ]: " _v
    CSW_CONTACT_PHONE="${_v:-}"
    [[ -z "$CSW_CONTACT_PHONE" ]] && break
    if ! [[ "$CSW_CONTACT_PHONE" =~ ^[0-9]+$ ]]; then
      echo -e "  ${R}✗${NC} Hanya angka yang diizinkan — tidak boleh ada huruf, spasi, atau simbol."
      continue
    fi
    if (( ${#CSW_CONTACT_PHONE} < 5 )); then
      echo -e "  ${R}✗${NC} Nomor terlalu pendek — minimal 5 digit."
      continue
    fi
    if (( ${#CSW_CONTACT_PHONE} > 20 )); then
      echo -e "  ${R}✗${NC} Nomor terlalu panjang — maksimal 20 digit."
      continue
    fi
    break
  done
  echo -e "  ${DIM}Email kontak yang tampil di GetCapabilities CSW (opsional).${NC}"
  local CSW_CONTACT_EMAIL
  while true; do
    read -rp "  Email kontak CSW (opsional)                 [  ]: " _v
    CSW_CONTACT_EMAIL="${_v:-}"
    if [[ -n "$CSW_CONTACT_EMAIL" ]] && ! _valid_email "$CSW_CONTACT_EMAIL"; then
      echo -e "  ${R}✗${NC} Format email tidak valid. Contoh: ${W}metadata@instansi.go.id${NC} — atau kosongkan."
      continue
    fi
    break
  done
  read -rp "  Faksimili (opsional)                        [  ]: " _v
  local CSW_CONTACT_FAX="${_v:-}"
  read -rp "  Negara                     [Indonesia]: " _v
  local CSW_CONTACT_COUNTRY="${_v:-Indonesia}"
  read -rp "  Website instansi (opsional)                 [  ]: " _v
  local CSW_CONTACT_URL="${_v:-}"
  read -rp "  Jam operasional            [08:00-16:00]: " _v
  local CSW_CONTACT_HOURS="${_v:-08:00-16:00}"
  read -rp "  Instruksi kontak           [Senin-Jumat]: " _v
  local CSW_CONTACT_INSTRUCTIONS="${_v:-Senin-Jumat}"
  read -rp "  Peran kontak               [Walidata]: " _v
  local CSW_CONTACT_ROLE="${_v:-Walidata}"

  # ── Preview & konfirmasi ──────────────────────────────────────────────────
  local _nginx_mode="Tidak digunakan (akses langsung via port)"
  [[ "$use_nginx" == "true" && "$ext_nginx" == "false" ]] && _nginx_mode="Docker container (dikelola deploy.sh)"
  [[ "$use_nginx" == "true" && "$ext_nginx" == "true"  ]] && _nginx_mode="Eksternal (Nginx di luar Docker)"

  echo ""
  echo -e "${W}  ┌──────────────────────────────────────────────────────────────────┐"
  echo    "  │              RINGKASAN KONFIGURASI — PERIKSA SEBELUM LANJUT       │"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "URL Publik (lengkap):" "$FULL_APP_URL"
  printf  "  │  %-28s %-37s│\n" "Sub-path:"            "${BASE_PATH:-(root /)}"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "Email admin:"         "$SEED_ADMIN_EMAIL"
  printf  "  │  %-28s %-37s│\n" "Nama admin:"          "$SEED_ADMIN_NAME"
  printf  "  │  %-28s %-37s│\n" "Organisasi:"          "$SEED_ADMIN_ORG"
  printf  "  │  %-28s %-37s│\n" "Jabatan:"             "$SEED_ADMIN_JABATAN"
  printf  "  │  %-28s %-37s│\n" "No. WhatsApp:"        "${SEED_ADMIN_TELEPON:-(tidak diisi)}"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "Nginx:"               "$_nginx_mode"
  if [[ -n "$P_HTTP" ]]; then
    printf "  │  %-28s %-37s│\n" "Port HTTP/HTTPS:"     "${P_HTTP} / ${P_HTTPS}"
  fi
  printf  "  │  %-28s %-37s│\n" "Port App:"            "$P_APP"
  printf  "  │  %-28s %-37s│\n" "Port PostgreSQL:"     "$P_PG"
  printf  "  │  %-28s %-37s│\n" "Port Redis:"          "$P_REDIS"
  printf  "  │  %-28s %-37s│\n" "Port MinIO API:"      "$P_MINIO"
  printf  "  │  %-28s %-37s│\n" "Port MinIO Console:"  "$P_MINIO_CON"
  printf  "  │  %-28s %-37s│\n" "Port pycsw:"          "$P_PYCSW"
  printf  "  │  %-28s %-37s│\n" "Port ext-serv:"       "$P_EXT"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "MinIO root user:"     "$MINIO_USER"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "Email (SMTP):"        "Dikonfigurasi via dashboard admin"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "Dashboard ext-serv user:"  "$UI_USER"
  printf  "  │  %-28s %-37s│\n" "Swagger UI user:"     "$SWAGGER_USER"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  local _wa_label; [[ "$wa_enabled" == "true" ]] && _wa_label="Aktif (+Chromium, build besar)" || _wa_label="Nonaktif (skip Chromium)"
  printf  "  │  %-28s %-37s│\n" "WhatsApp OTP:"        "$_wa_label"
  echo    "  ├──────────────────────────────────────────────────────────────────┤"
  printf  "  │  %-28s %-37s│\n" "CSW Judul:"           "$CSW_TITLE"
  printf  "  │  %-28s %-37s│\n" "CSW Penyedia:"        "$CSW_PROVIDER_NAME"
  printf  "  │  %-28s %-37s│\n" "CSW Kontak:"          "${CSW_CONTACT_NAME} / ${CSW_CONTACT_EMAIL:-—}"
  printf  "  │  %-28s %-37s│\n" "CSW Kota:"            "${CSW_CONTACT_CITY}, ${CSW_CONTACT_PROVINCE}"
  echo -e "  └──────────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "  ${Y}Password admin dan semua secret di-generate otomatis.${NC}"
  echo ""
  read -rp "  Semua isian sudah benar? Lanjutkan generate .env? (y/N): " _confirm
  [[ "${_confirm,,}" == "y" ]] || { warn "Dibatalkan. Jalankan ulang menu 9 untuk mengisi ulang."; return; }

  # ── Generate secrets ──────────────────────────────────────────────────────
  echo ""
  info "Membuat secrets..."

  local PG_PASS REDIS_PASS MINIO_PASS APP_JWT APP_SECRET ENC_KEY IP_SALT HEALTH_KEY SHARED_KEY EXT_JWT SWAGGER_PASS
  PG_PASS=$(openssl rand -hex 24)
  REDIS_PASS=$(openssl rand -hex 24)
  MINIO_PASS=$(openssl rand -hex 24)
  APP_JWT=$(openssl rand -hex 32)
  APP_SECRET=$(openssl rand -hex 32)
  ENC_KEY=$(openssl rand -hex 32)      # kunci enkripsi field sensitif DB (email, telepon)
  IP_SALT=$(openssl rand -hex 16)      # salt untuk hash IP pada view katalog
  HEALTH_KEY=$(openssl rand -hex 24)   # API key untuk monitoring health endpoint
  SHARED_KEY=$(openssl rand -hex 32)   # kunci integrasi: sama di kedua .env
  EXT_JWT=$(openssl rand -hex 32)
  SWAGGER_PASS=$(openssl rand -hex 16)
  [[ -n "$UI_PASS" ]] || UI_PASS=$(openssl rand -hex 12)

  ok "Secrets berhasil di-generate."

  # ── Tulis .env (main app) ─────────────────────────────────────────────────
  cat > .env <<MAINENV
# ════════════════════════════════════════════════════════════
#  Geomdb Hub — Environment Configuration
#  Di-generate oleh deploy.sh — $(date '+%Y-%m-%d %H:%M:%S')
# ════════════════════════════════════════════════════════════
#
#  Cara mengubah konfigurasi:
#  1. Edit file ini langsung:  nano .env  (atau vim / editor lain)
#  2. Restart container sesuai jenis perubahan:
#
#     Perubahan runtime (URL, secret, CSW, port, ext-serv):
#       docker compose up -d --force-recreate
#
#     Perubahan build-time (NEXT_PUBLIC_*, WA_ENABLED, BASE_PATH):
#       docker compose up -d --build app
#
#  ⚠  JANGAN ubah setelah data ada — akan merusak data yang tersimpan:
#     POSTGRES_PASSWORD · MINIO_ROOT_PASSWORD · REDIS_PASSWORD
#     ENCRYPTION_KEY · NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
# ════════════════════════════════════════════════════════════

# ─── Database ────────────────────────────────────────────────
# Untuk local dev (Next.js langsung, tanpa Docker):
DATABASE_URL="postgresql://geomdb:${PG_PASS}@localhost:${P_PG}/geomdb_hub"
# Di Docker, di-override otomatis oleh docker-compose.yml

# ─── Auth ────────────────────────────────────────────────────
JWT_SECRET="${APP_JWT}"
APP_SECRET="${APP_SECRET}"
# Kunci terpisah untuk enkripsi field sensitif (email, telepon) di DB.
# Pisah dari JWT_SECRET agar rotasi salah satu tidak merusak yang lain.
ENCRYPTION_KEY="${ENC_KEY}"
# COOKIE_SECURE=false  # uncomment jika local dev via HTTP

# ─── Aplikasi ────────────────────────────────────────────────
NEXT_PUBLIC_APP_URL="${FULL_APP_URL}"
APP_URL="${FULL_APP_URL}"
$(  [[ -n "${BASE_PATH}" ]] && echo "NEXT_PUBLIC_BASE_PATH=${BASE_PATH}" )
$(  [[ -n "${CUSTOM_APP_IMAGE}" ]] && echo "GEOMDB_APP_IMAGE=${CUSTOM_APP_IMAGE}" )
WA_ENABLED=${wa_enabled}
NEXT_PUBLIC_WA_ENABLED=${wa_enabled}
NODE_ENV="production"
# Salt untuk hashing IP pada log view katalog (UU PDP compliance).
IP_SALT="${IP_SALT}"

# ─── Registry GHCR (opsional) ────────────────────────────────
# Isi jika ingin pakai image dari GitLab CI daripada build lokal.
# Format: ghcr.io/<namespace>/<project>
# Kosongkan (hapus atau komen) untuk tetap build lokal.
# Pilih variant sesuai kondisi server:
#   app-geoportal    → server yang punya geoportal (BASE_PATH=/geomdb-hub)
#   app-standalone → server dedicated tanpa geoportal
# GEOMDB_APP_IMAGE=ghcr.io/harihk1/geomdb-hub/app-geoportal
# GEOMDB_MIGRATE_IMAGE=ghcr.io/harihk1/geomdb-hub/migrate
# GEOMDB_EXT_SERV_IMAGE=ghcr.io/harihk1/geomdb-hub/ext-serv
# GEOMDB_IMAGE_TAG=latest

# ─── Docker services ─────────────────────────────────────────
POSTGRES_PASSWORD="${PG_PASS}"
MINIO_ROOT_USER="${MINIO_USER}"
MINIO_ROOT_PASSWORD="${MINIO_PASS}"

# ─── Redis ───────────────────────────────────────────────────
REDIS_PASSWORD="${REDIS_PASS}"
# Sertakan password di URL — Redis dijalankan dengan --requirepass.
# Tanpa ini, app yang dijalankan langsung (npm, di luar Docker) gagal NOAUTH.
REDIS_URL="redis://:${REDIS_PASS}@localhost:${P_REDIS}"
# Di Docker: di-override ke redis://:password@redis:6379 (lihat docker-compose.yml)

# ─── MinIO ───────────────────────────────────────────────────
MINIO_URL="http://localhost:${P_MINIO}"
MINIO_ENDPOINT="localhost"
MINIO_PORT="${P_MINIO}"
MINIO_BUCKET="geomdb-hub"
# Di Docker: di-override ke http://minio:9000

# ─── pycsw ───────────────────────────────────────────────────
PYCSW_URL="http://localhost:${P_PYCSW}"
NEXT_PUBLIC_PYCSW_URL="${FULL_APP_URL}/csw"
# Di Docker: di-override ke http://pycsw:8000
# Untuk production, NEXT_PUBLIC_PYCSW_URL harus URL yang bisa diakses browser.

# ─── CSW Identitas Layanan ────────────────────────────────────
# Dipakai oleh pycsw (via docker-compose env) saat container start.
# Built-in CSW juga bisa dikonfigurasi via menu admin → Pengaturan CSW.
CSW_TITLE="${CSW_TITLE}"
CSW_ABSTRACT="${CSW_ABSTRACT}"
CSW_KEYWORDS="${CSW_KEYWORDS}"
CSW_FEES="${CSW_FEES}"
CSW_ACCESS_CONSTRAINTS="${CSW_ACCESS_CONSTRAINTS}"
CSW_PROVIDER_NAME="${CSW_PROVIDER_NAME}"
CSW_CONTACT_NAME="${CSW_CONTACT_NAME}"
CSW_CONTACT_POSITION="${CSW_CONTACT_POSITION}"
CSW_CONTACT_ADDRESS="${CSW_CONTACT_ADDRESS}"
CSW_CONTACT_CITY="${CSW_CONTACT_CITY}"
CSW_CONTACT_PROVINCE="${CSW_CONTACT_PROVINCE}"
CSW_CONTACT_POSTALCODE="${CSW_CONTACT_POSTALCODE}"
CSW_CONTACT_PHONE="${CSW_CONTACT_PHONE}"
CSW_CONTACT_FAX="${CSW_CONTACT_FAX}"
CSW_CONTACT_EMAIL="${CSW_CONTACT_EMAIL}"
CSW_CONTACT_COUNTRY="${CSW_CONTACT_COUNTRY}"
CSW_CONTACT_URL="${CSW_CONTACT_URL}"
CSW_CONTACT_HOURS="${CSW_CONTACT_HOURS}"
CSW_CONTACT_INSTRUCTIONS="${CSW_CONTACT_INSTRUCTIONS}"
CSW_CONTACT_ROLE="${CSW_CONTACT_ROLE}"

# ─── OAuth2 Docker networking ────────────────────────────────
# Agar server-side token exchange ke provider OAuth2 yang berjalan di host
# (mis. localhost) bisa diakses dari dalam container Docker.
DOCKER_INTERNAL_HOST=host.docker.internal

# ─── Geoportal integration (opsional) ────────────────────────
# Nama Docker network geoportal (GeoNode, ArcGIS Portal, dll.) agar
# nginx geoportal bisa proxy ke geomdb_app.
# Kosongkan jika geomdb tidak dijalankan bersama geoportal.
GEOPORTAL_NETWORK=${GEOPORTAL_NETWORK}

# ─── ext-serv (Email + WhatsApp API) ─────────────────────────
EXT_SERV_URL="http://localhost:${P_EXT}"
EXT_SERV_API_KEY="${SHARED_KEY}"
# Di Docker: EXT_SERV_URL di-override ke http://ext-serv:3007

# ─── ArcGIS probe allowlist ───────────────────────────────────
# Domain yang diizinkan untuk probe ketersediaan service ArcGIS (publik, tanpa login).
# Pisahkan dengan koma. Subdomain otomatis diizinkan (go.id → *.go.id).
# Kosongkan untuk memblokir semua probe dari publik.
ARCGIS_PROBE_DOMAINS=${ARCGIS_PROBE_DOMAINS}

# ─── Health check (monitoring) ───────────────────────────────
# Dipakai oleh tools monitoring (Uptime Kuma, Prometheus, dll.)
# sebagai Bearer token ke GET /api/health
HEALTH_API_KEY="${HEALTH_KEY}"

# ─── GeoNode integration (opsional) ──────────────────────────
# Isi jika ingin sinkron metadata ke GeoNode. Bisa juga dikonfigurasi
# via menu admin → Pengaturan → GeoNode.
# GEONODE_URL=https://geonode.example.com
# GEONODE_CLIENT_ID=your_client_id
# GEONODE_CLIENT_SECRET=your_client_secret
# GEONODE_CSW_USER=admin
# GEONODE_CSW_PASSWORD=your_password

# ─── Network ─────────────────────────────────────────────────
# Subnet khusus agar tidak tabrakan dengan geoportal (172.18.x.x) atau stack lain.
# Ganti jika subnet ini sudah dipakai jaringan lain di server.
GEOMDB_SUBNET=${GEOMDB_SUBNET}

# ─── Port overrides (docker-compose) ─────────────────────────
$(  [[ -n "${P_HTTP}" ]]  && echo "PORT_HTTP=${P_HTTP}"  )
$(  [[ -n "${P_HTTPS}" ]] && echo "PORT_HTTPS=${P_HTTPS}" )
PORT_APP=${P_APP}
PORT_POSTGRES=${P_PG}
PORT_REDIS=${P_REDIS}
PORT_MINIO_API=${P_MINIO}
PORT_MINIO_CONSOLE=${P_MINIO_CON}
PORT_PYCSW=${P_PYCSW}
PORT_EXT_SERV=${P_EXT}

# ─── WARP (Cloudflare WireGuard) ─────────────────────────────
# WARP diaktifkan otomatis jika koneksi ke host:port di bawah gagal (diblokir ISP).
# Ubah jika provider SMTP Anda bukan Gmail.
# WARP_CHECK_HOST=smtp.gmail.com
# WARP_CHECK_PORT=465

# ─── Nginx ───────────────────────────────────────────────────
# true  = Nginx dikelola di luar Docker (tidak perlu certbot/nginx container)
# false = Nginx dijalankan sebagai Docker container oleh deploy.sh
# Jika USE_NGINX=false, Nginx tidak digunakan sama sekali
USE_NGINX=${use_nginx}
USE_EXTERNAL_NGINX=${ext_nginx}

# ─── Seed Admin (hanya dipakai saat seed pertama kali) ───────
SEED_ADMIN_EMAIL="${SEED_ADMIN_EMAIL}"
SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD}"
SEED_ADMIN_NAME="${SEED_ADMIN_NAME}"
SEED_ADMIN_ORG="${SEED_ADMIN_ORG}"
SEED_ADMIN_JABATAN="${SEED_ADMIN_JABATAN}"
$(  [[ -n "${SEED_ADMIN_TELEPON}" ]] && echo "SEED_ADMIN_TELEPON=${SEED_ADMIN_TELEPON}" )
MAINENV

  chmod 600 .env
  ok "Berhasil menulis .env (chmod 600)"

  # ── Tulis ext_serv-main/.env ──────────────────────────────────────────────
  # Di installer mode folder ext_serv-main/ tidak ada (tanpa source), tapi file
  # .env tetap diperlukan — docker-compose memuatnya via env_file untuk
  # SWAGGER_USER, UI_USERNAME, JWT_SECRET, PUPPETEER_EXECUTABLE_PATH, dll.
  mkdir -p ext_serv-main
  cat > ext_serv-main/.env <<EXTENV
# ════════════════════════════════════════════════════════════
#  ext-serv — Environment Configuration
#  Di-generate oleh deploy.sh — $(date '+%Y-%m-%d %H:%M:%S')
#
#  API_SECRET_KEY HARUS SAMA dengan EXT_SERV_API_KEY di .env utama.
#  Keduanya sudah sinkron karena di-generate bersama oleh deploy.sh.
# ════════════════════════════════════════════════════════════

# ─── Server ──────────────────────────────────────────────────
PORT=3007
NODE_ENV=production

# Origins yang diizinkan (CORS) — pisahkan dengan koma
ALLOWED_ORIGINS=${APP_URL},http://localhost:${P_APP}

# ─── API Authentication ───────────────────────────────────────
# HARUS SAMA dengan EXT_SERV_API_KEY di .env utama
API_SECRET_KEY=${SHARED_KEY}

# ─── Swagger UI ───────────────────────────────────────────────
SWAGGER_USER=${SWAGGER_USER}
SWAGGER_PASSWORD=${SWAGGER_PASS}

# ─── WhatsApp ─────────────────────────────────────────────────
# false = skip Chromium & whatsapp-web.js (rebuild diperlukan jika diubah)
WA_ENABLED=${wa_enabled}
WA_SESSION_DIR=./.wwebjs_auth
# Path Chromium di dalam Docker image (sudah terinstall di image ext-serv).
# Ganti jika Chromium berada di lokasi berbeda di server Anda.
PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# ─── Dashboard UI Auth ────────────────────────────────────────
UI_USERNAME=${UI_USER}
UI_PASSWORD=${UI_PASS}
JWT_SECRET=${EXT_JWT}
JWT_EXPIRES=8h

# ─── Mail Server ──────────────────────────────────────────────
# Konfigurasi SMTP dikelola via dashboard admin (Pengaturan Org → Email)
# dan disimpan di database. Env var di bawah hanya sebagai fallback
# apabila konfigurasi DB belum diisi.
MAIL_TIMEOUT=10000

# ─── Mail Fallback SMTP (opsional) ────────────────────────────
# Aktifkan jika ingin fallback SMTP kedua (dikonfigurasi manual):
# MAIL_FALLBACK_HOST=smtp.resend.com
# MAIL_FALLBACK_PORT=587
# MAIL_FALLBACK_SECURE=false
# MAIL_FALLBACK_USER=resend
# MAIL_FALLBACK_PASS=your_resend_api_key_here
# MAIL_FALLBACK_FROM=No Reply <onboarding@resend.dev>
# MAIL_FALLBACK_TIMEOUT=10000

# ─── Resend HTTP API (fallback terakhir, opsional) ────────────
# RESEND_API_KEY=re_your_api_key_here
# RESEND_FROM=No Reply <onboarding@resend.dev>
EXTENV

  chmod 600 ext_serv-main/.env
  ok "Berhasil menulis ext_serv-main/.env (chmod 600)"

  # ── Summary credential ────────────────────────────────────────────────────
  echo ""
  echo -e "${Y}${W}"
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  echo "  │          SIMPAN CREDENTIAL BERIKUT DI TEMPAT AMAN !              │"
  echo "  ├──────────────────────────────────────────────────────────────────┤"
  printf "  │  %-36s %-27s │\n" "Admin email:"                  "$SEED_ADMIN_EMAIL"
  printf "  │  %-36s %-27s │\n" "Admin password:"               "$SEED_ADMIN_PASSWORD"
  printf "  │  %-36s %-27s │\n" "PostgreSQL password:"          "$PG_PASS"
  printf "  │  %-36s %-27s │\n" "MinIO password:"               "$MINIO_PASS"
  printf "  │  %-36s %-27s │\n" "ext-serv UI (${UI_USER}):"       "$UI_PASS"
  printf "  │  %-36s %-27s │\n" "ext-serv Swagger (${SWAGGER_USER}):"  "$SWAGGER_PASS"
  printf "  │  %-36s %-27s │\n" "Shared API Key (32 byte):"     "${SHARED_KEY:0:27}..."
  echo "  └──────────────────────────────────────────────────────────────────┘"
  echo -e "${NC}"

  echo -e "  ${G}File yang dibuat:${NC}"
  echo -e "  • ${C}.env${NC}                 — main app (Next.js + Docker)"
  echo -e "  • ${C}ext_serv-main/.env${NC}   — ext-serv (email + WhatsApp)"
  echo ""
  echo -e "  ${DIM}Langkah selanjutnya:${NC}"
  if ! _is_installer_mode; then
    echo -e "  ${DIM}  • Deploy lokal  → menu 3${NC}"
  fi
  echo -e "  ${DIM}  • Deploy server → menu 4 (lalu atur SSL di menu 8)${NC}"
}

# ─── r. Start/restart containers (tanpa rebuild) ─────────────────────────────
fn_start_containers() {
  load_env
  echo -e "\n${W}  Start/Restart Containers${NC} — tanpa rebuild image"
  echo "  ─────────────────────────────"
  echo -e "  ${DIM}Gunakan menu ini jika container mati (server reboot, docker stop, dsb).${NC}"
  echo -e "  ${DIM}Image yang sudah ada akan langsung dipakai — tidak ada proses build.${NC}"
  echo ""
  echo "  1) Dengan Nginx   — jalankan semua service termasuk nginx"
  echo "  2) Tanpa Nginx    — jalankan semua kecuali nginx (akses via port ${PORT_APP:-3000})"
  echo "  0) Kembali"
  echo ""
  read -rp "  Pilih: " choice

  case $choice in
    1)
      info "Menjalankan semua containers (termasuk nginx)..."
      docker compose up -d --remove-orphans
      ok "Semua containers running."
      echo ""
      docker compose ps
      ;;
    2)
      info "Menjalankan containers tanpa nginx..."
      docker compose up -d --remove-orphans --scale nginx=0 postgres redis minio pycsw app migrate ext-serv
      ok "Containers running (tanpa nginx)."
      echo ""
      echo -e "  ${W}Akses aplikasi: ${C}http://$(hostname -I | awk '{print $1}'):${PORT_APP:-3000}${NC}"
      docker compose ps
      ;;
    0) return ;;
    *) warn "Pilihan tidak valid." ;;
  esac
}

main_menu() {
  _load_env_quiet
  # Deteksi mode: installer (tidak ada .git) vs development (ada .git)
  local _has_git=false
  git rev-parse --git-dir &>/dev/null && _has_git=true

  while true; do
    show_header
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  9. Generate .env    (setup awal)            │"
    echo "  │  ─────────────────────────────────────────  │"
    if [[ "$_has_git" == "true" ]]; then
    echo "  │  1. Switch branch                            │"
    echo "  │  2. Pull (git pull)                          │"
    fi
    if ! _is_installer_mode; then
    echo "  │  3. Deploy lokal   (tanpa Nginx, port ${PORT_APP:-3000})  │"
    fi
    echo "  │  4. Deploy server  (install → nginx → ssl)   │"
    echo "  │  r. Start/restart  (up -d, tanpa rebuild)    │"
    echo "  │  ─────────────────────────────────────────  │"
    echo "  │  5. Clean Docker   (system prune)            │"
    echo "  │  6. Manajemen migrasi DB                     │"
    echo "  │  7. Flush Redis                              │"
    echo "  │  8. Konfigurasi SSL                          │"
    echo "  │  b. Backup & Restore                         │"
    echo "  │  0. Keluar                                   │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
    read -rp "  Pilih menu: " choice
    echo ""

    case $choice in
      9) fn_generate_env ;;
      1) [[ "$_has_git" == "true" ]] && fn_switch_branch || warn "Menu ini hanya tersedia di mode development." ;;
      2) [[ "$_has_git" == "true" ]] && fn_pull         || warn "Menu ini hanya tersedia di mode development." ;;
      3) _is_installer_mode && warn "Deploy lokal tidak tersedia di installer mode (butuh source code). Gunakan menu 4." || fn_deploy_local ;;
      4) fn_deploy ;;
      r|R) fn_start_containers ;;
      5) fn_clean_docker ;;
      6) fn_db_menu ;;
      7) fn_flush_redis ;;
      8) fn_ssl_menu ;;
      b|B) fn_backup_menu ;;
      0) echo -e "${G}  Sampai jumpa!${NC}\n"; exit 0 ;;
      *) warn "Pilihan tidak valid." ;;
    esac

    echo ""
    read -rp "  Tekan Enter untuk kembali ke menu..." _
  done
}

# Pastikan dijalankan dari folder installer (ada docker-compose.yml)
if [[ ! -f "docker-compose.yml" ]]; then
  echo "Error: jalankan deploy.sh dari folder installer (harus ada docker-compose.yml)."
  exit 1
fi

# ─── Cek & instal Docker ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo ""
  warn "Docker belum terinstal di sistem ini."
  echo -e "  ${DIM}Docker diperlukan untuk menjalankan geomdb-hub.${NC}"
  echo ""
  read -rp "  Instal Docker sekarang secara otomatis? (Y/n): " _v
  if [[ "${_v,,}" == "n" ]]; then
    err "Docker diperlukan. Instal terlebih dahulu lalu jalankan ulang deploy.sh."
    echo -e "  ${DIM}Panduan: https://docs.docker.com/engine/install/${NC}"
    exit 1
  fi
  echo ""
  info "Mengunduh dan menginstal Docker via script resmi (get.docker.com)..."
  echo -e "  ${DIM}Diperlukan koneksi internet dan izin sudo.${NC}"
  echo ""
  if ! curl -fsSL https://get.docker.com | sudo sh; then
    err "Gagal menginstal Docker."
    echo -e "  ${DIM}Coba instal manual: https://docs.docker.com/engine/install/${NC}"
    exit 1
  fi
  ok "Docker berhasil diinstal."
  # Tambah user ke grup docker agar tidak perlu sudo tiap perintah
  if ! id -nG "$USER" 2>/dev/null | grep -qw "docker"; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    echo ""
    warn "User '${USER}' ditambahkan ke grup docker."
    warn "Jalankan  newgrp docker  atau logout/login ulang agar berlaku tanpa sudo."
  fi
  echo ""
fi

# Cek Docker daemon berjalan
if ! docker info &>/dev/null; then
  warn "Docker daemon tidak berjalan — mencoba start..."
  sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
  sleep 2
  if ! docker info &>/dev/null; then
    err "Docker daemon gagal distart. Jalankan: sudo systemctl start docker"
    exit 1
  fi
  ok "Docker daemon berhasil distart."
fi

# Cek docker compose plugin
if ! docker compose version &>/dev/null; then
  err "Docker Compose plugin tidak ditemukan."
  echo -e "  ${DIM}Instal plugin: sudo apt install docker-compose-plugin  (Debian/Ubuntu)${NC}"
  echo -e "  ${DIM}Atau update Docker ke versi terbaru via get.docker.com${NC}"
  exit 1
fi

# Auto-run generate .env jika belum ada
if [[ ! -f ".env" ]]; then
  echo -e "\n${Y}⚠  File .env belum ditemukan — menjalankan setup awal...${NC}\n"
  fn_generate_env
fi

# Aktifkan override geoportal hanya jika GEOPORTAL_NETWORK terisi di .env
if grep -qE '^GEOPORTAL_NETWORK=.+' .env 2>/dev/null; then
  export COMPOSE_FILE="docker-compose.yml:docker-compose.geoportal.yml"
fi

main_menu
