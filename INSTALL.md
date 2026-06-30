# geoMDB-hub — Panduan Instalasi

Panduan ini untuk instalasi menggunakan **image yang sudah dibangun** (dari registry atau file offline).
Tidak memerlukan source code, Node.js, atau npm.

## Prasyarat

- Docker Engine 24+ dan Docker Compose V2
- Ubuntu 22.04 LTS / Debian 12
- 4 GB RAM minimum (8 GB jika WhatsApp aktif)
- Domain dengan DNS yang sudah mengarah ke server

```bash
# Install Docker (jika belum ada)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

---

## Cara Install

### Mode 1: Registry (butuh internet)

```bash
git clone https://github.com/hariHK1/geomdb-hub-installer.git
cd geomdb-hub-installer
bash deploy.sh
```

Saat wizard meminta cara instalasi, pilih **Registry GitHub**.
Siapkan Personal Access Token dari GitHub → Settings → Developer settings → Personal access tokens (scope: `read:packages`).

---

### Mode 2: Offline (tanpa internet)

**Download file berikut dari halaman Rilis:**

👉 **https://github.com/hariHK1/geomdb-hub-installer/releases/latest**

| File | Keterangan | Wajib? |
| ---- | ---------- | :----: |
| `geomdb-hub-vX.Y.Z-installer.tar.gz` | Deployment files (docker-compose, deploy.sh, config) | ✓ |
| `geomdb-hub-vX.Y.Z-images.tar.gz` | Docker image aplikasi | ✓ |
| `geomdb-hub-vX.Y.Z-infra.tar.gz` | Docker image infrastruktur (postgres, redis, minio, dll.) | Hanya jika server baru / belum punya image infra |

> **Tips:** Anda dapat mengunduh file-file ini lewat browser di komputer lokal, lalu upload ke server via `scp`:
> ```bash
> scp geomdb-hub-vX.Y.Z-*.tar.gz user@ip-server:/home/user/
> ```

Setelah semua file berada di server:

```bash
# Ekstrak installer
tar -xzf geomdb-hub-vX.Y.Z-installer.tar.gz
cd geomdb-hub

# Pindahkan/salin file images ke folder yang sama
mv /home/user/geomdb-hub-vX.Y.Z-images.tar.gz .
mv /home/user/geomdb-hub-vX.Y.Z-infra.tar.gz .   # jika server baru

# Jalankan wizard
bash deploy.sh
```

Saat wizard meminta cara instalasi, pilih **File installer**.

---

## Mengubah Konfigurasi (.env)

Di installer mode, image **sudah jadi (prebuilt)** — Anda tidak melakukan build di server.
Cara menerapkan perubahan `.env` tergantung jenis variabelnya.

### A. Variabel Runtime — cukup restart (TANPA rebuild)

Mayoritas variabel dibaca saat container **start**. Edit `.env`, lalu jalankan ulang:

```bash
nano .env                    # ubah nilai
docker compose up -d         # recreate container dengan env baru
```

Termasuk dalam kategori ini:
- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `MINIO_ROOT_PASSWORD`, `EXT_SERV_API_KEY`
- `SYSTEM_CERT_P12_PATH`, `SYSTEM_CERT_PASSWORD` (auto-TTE)
- `DB_POOL_MAX`, port-port (`PORT_APP`, dll.)
- Konfigurasi SMTP, OTP, WhatsApp — **ini dikonfigurasi via UI Admin → Pengaturan Org.**, bukan `.env`

> Mengubah `POSTGRES_PASSWORD`/`REDIS_PASSWORD`/`MINIO_ROOT_PASSWORD` setelah data ada
> akan memutus koneksi ke data lama. Jangan ubah password storage setelah produksi
> kecuali Anda juga mereset/migrasi volume-nya.

### B. Variabel `NEXT_PUBLIC_*` — TIDAK bisa diubah via .env

Empat variabel ini **di-bake ke dalam image** saat build (di-inline ke bundle JavaScript browser):
- `NEXT_PUBLIC_APP_URL`
- `NEXT_PUBLIC_BASE_PATH`
- `NEXT_PUBLIC_PYCSW_URL`
- `NEXT_PUBLIC_WA_ENABLED`

Mengeditnya di `.env` **tidak berpengaruh** karena image sudah dikompilasi. Untuk mengubahnya:

1. **Minta image baru ke maintainer** — maintainer build ulang dengan nilai yang benar
   (`bash scripts/make-release.sh`), lalu kirim `geomdb-hub-vX.Y.Z-images.tar.gz` baru.
2. **Mode registry**: pilih varian image yang sesuai:
   - `app-standalone` — untuk domain root (`https://domain.com`)
   - `app-geoportal` — untuk sub-path `/geomdb-hub` (`https://domain.com/geomdb-hub`)

   deploy.sh memilih otomatis berdasarkan apakah `GEONODE_NETWORK` diset.

> **Ringkas:** ganti domain/base-path = butuh image baru. Ganti password/secret/cert = cukup `docker compose up -d`.

---

## Update Versi Baru

### Mode registry:
```bash
cd geomdb-hub
bash deploy.sh
# Pilih menu: r (Start/restart) → atau Deploy server untuk update penuh
```

### Mode offline:
```bash
# Terima file images versi baru dari maintainer
docker load < geomdb-hub-vNEW-images.tar.gz
docker compose up -d
```

---

## Setelah Install

1. Buka `https://yourdomain.com` di browser
2. Login dengan email dan password admin yang dikonfigurasi saat setup
3. Masuk ke **Pengaturan Org.** untuk mengonfigurasi SMTP, OTP, mode QC/QE
4. Buat akun Walidata, Pemeriksa, Produsen

Lihat [README.md](README.md) untuk dokumentasi lengkap alur bisnis dan fitur.
Prosedur penanganan insiden (runbook) diberikan terpisah kepada operator.
