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
git clone -b installer https://github.com/hariHK1/geomdb-hub.git
cd geomdb-hub
bash deploy.sh
```

Saat wizard meminta cara instalasi, pilih **Registry GitHub**.
Siapkan Personal Access Token dari GitHub → Settings → Developer settings → Personal access tokens (scope: `read:packages`).

---

### Mode 2: Offline (tanpa internet)

Dapatkan file berikut dari maintainer atau tim IT:
- `geomdb-hub-vX.Y.Z-installer.tar.gz` — deployment files
- `geomdb-hub-vX.Y.Z-images.tar.gz` — app images
- `geomdb-hub-vX.Y.Z-infra.tar.gz` — infra images *(jika server baru)*

```bash
# Ekstrak installer
tar -xzf geomdb-hub-vX.Y.Z-installer.tar.gz
cd geomdb-hub

# Letakkan file images di folder yang sama
cp /path/to/geomdb-hub-vX.Y.Z-images.tar.gz .
cp /path/to/geomdb-hub-vX.Y.Z-infra.tar.gz .   # jika server baru

# Jalankan wizard
bash deploy.sh
```

Saat wizard meminta cara instalasi, pilih **File installer**.

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
Lihat [RUNBOOK.md](RUNBOOK.md) untuk prosedur penanganan insiden.
