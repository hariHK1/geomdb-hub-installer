# Thumbnail: Empat Lapis Jalur

Dokumen ini menjelaskan dari mana gambar pratinjau (thumbnail) sebuah dataset
bisa datang, dan mengapa sebagian tipe layanan tidak akan pernah punya
thumbnail meskipun metadatanya lengkap.

Ditulis karena pertanyaan "kok tidak dapat thumbnail?" hampir selalu punya
jawaban yang berbeda tergantung tipe layanannya — bukan satu bug tunggal.

## Ringkasan

Ada **empat lapis** yang dicoba, bukan satu. Lapisnya berbeda sumber, berbeda
biaya, dan berbeda pula kapan dipakainya.

| Lapis | Sumber gambar | Dipakai di |
|-------|---------------|------------|
| **A** | URL gambar yang tertulis di dalam record CSW | dialog CSW Harvester |
| **B** | Komposit: basemap + layer dirender dari layanannya | katalog & kartu data |
| **C** | Cadangan warisan bila komposit gagal | katalog & kartu data |
| **D** | Field `thumbnailUrl` yang tersimpan di metadata | semua |

Lapis **A hanya ada di dialog harvester**. Setelah metadata diimpor, record
CSW-nya tidak ikut tersimpan, jadi jalur itu hilang.

---

## Lapis A — dari record CSW

Dicari di elemen `dct:references`, `ref`, dan URI lain pada record. Empat
kondisi, dipakai berurutan sampai ada yang cocok:

1. Atribut `scheme` mengandung kata `thumbnail`
2. Atribut `scheme` diawali `image/`
3. URL berakhiran `.jpg` `.jpeg` `.png` `.gif` `.webp`
4. Ada URL mengandung `/rest/services/` → ditandai `arcgis:<url>`

Kondisi 4 juga menggantikan hasil 1–3 bila yang ditemukan ternyata placeholder
`images/thumbnail.png` — file bawaan GeoNode yang isinya bukan peta.

> **Catatan lapangan.** Banyak katalog pemerintah tidak menerbitkan browse
> graphic sama sekali. Contoh terukur: CSW Kabupaten Banyumas — `graphicOverview`
> 0×, `MD_BrowseGraphic` 0×, dan nol URL bergambar dari 22 URL dalam record.
> Recordnya hanya memuat identifier, judul, subject, satu `dct:references`
> ber-skema `OGC:WMS`, tanggal, abstrak, dan bounding box. Dalam keadaan ini
> lapis A tidak punya apa pun untuk diambil, dan itu **bukan** kerusakan.

## Lapis B — komposit (jalur utama)

Menggabungkan basemap yang kita render sendiri dengan layer yang diminta dari
layanan sumber. Dua bentuk permintaan:

| Tipe | Permintaan |
|------|-----------|
| WMS | `GetMap` dengan `VERSION=1.1.1`, bbox eksplisit |
| ArcGIS | `/export?f=image` |

`VERSION=1.1.1` disengaja: WMS 1.3.0 membalik urutan sumbu bbox untuk EPSG:4326
(lat,lon), jebakan klasik yang membuat overlay meleset jauh dari basemap.

## Lapis C — cadangan warisan

Hanya dicoba bila komposit gagal. Bukan pengulangan lapis B — keduanya menempuh
jalur berbeda, sehingga bisa berhasil justru saat B gagal:

| Tipe | Permintaan | Kenapa bisa berhasil saat B gagal |
|------|-----------|-----------------------------------|
| GeoServer | `/reflect` | server menghitung sendiri bbox & SRS-nya |
| ArcGIS | `/info/thumbnail` | gambar statis buatan penerbit layanan |

Dua penjaga sebelum hasilnya dipakai:

- `Content-Type` harus `image/*`
- Entropi gambar minimal **1.0** — menolak gambar kosong. Terukur di lapangan:
  gambar blank ~0.10, peta yang benar ~3.35.

## Lapis D — field tersimpan

`MetadataRecord.thumbnailUrl`, diisi manual atau saat impor. Satu kondisi: ada
atau tidak ada.

---

## Jalur efektif per tipe layanan

| Tipe layanan | A | B komposit | C cadangan | D | Efektif |
|---|:-:|---|---|:-:|:-:|
| WMS GeoServer | ✓ | `GetMap` ✓ | `/reflect` ✓ | ✓ | **4** |
| WMS non-GeoServer | ✓ | `GetMap` ✓ | `/reflect` ✗ | ✓ | **3** |
| ArcGIS MapServer | ✓ | `/export` ✓ | `/info/thumbnail` ✓ | ✓ | **4** |
| ArcGIS ImageServer | ✓ | ✗ tidak dikenali | ✗ tidak dikenali | ✓ | **2** |
| ArcGIS FeatureServer | ✓ | ✗ tidak dikenali | ✗ tidak dikenali | ✓ | **2** |
| OGC WFS | ✓ | ✗ | ✗ | ✓ | **2** |
| OGC WCS | ✓ | ✗ | ✗ | ✓ | **2** |
| Unduhan / tautan | ✓ | ✗ | ✗ | ✓ | **2** |

Ingat lapis A hilang setelah impor, jadi untuk **thumbnail katalog** angka di
kolom terakhir berkurang satu.

### Yang perlu diketahui operator

**Hanya MapServer yang dikenali di antara tipe ArcGIS.** `resolveLayerSource`
mencocokkan `/MapServer` saja, sehingga URL `/FeatureServer` dan `/ImageServer`
menghasilkan "tidak ada layanan" — lapis B dan C tidak pernah dicoba sama
sekali, bukan dicoba lalu gagal.

Dua hal terpisah yang mudah tertukar:

- **Pengenalan.** FeatureServer & ImageServer tidak diresolusi jadi sumber layer.
  Ini yang menentukan, dan berlaku lebih dulu.
- **Endpoint.** Seandainya dikenali pun, FeatureServer memang tidak punya
  `/export` — diuji ke `geoportal.pertanian.go.id`: `HTTP 400 — Output format
  not supported`, sedangkan MapServer di server yang sama membalas PNG.
  ImageServer memakai `/exportImage`, bukan `/export`.

Dukungan keduanya belum ditambahkan karena belum ada datanya: dari seluruh
metadata tersimpan, 28 sumber daya ArcGIS semuanya MapServer — FeatureServer 0,
ImageServer 0. Menambahkannya sekarang hanya menebak kebutuhan yang belum ada.

**WFS dan WCS praktis nol.** Keduanya mengembalikan data (GML, GeoTIFF), bukan
gambar. Dua "jalur" yang tersisa hanya berharap sumbernya mencantumkan URL
gambar sendiri, atau seseorang mengisi `thumbnailUrl` secara manual.

**Layanan yang sudah dihapus tetap terlihat lengkap di katalog.** Contoh
terukur: 6 dari 6 layanan ArcGIS yang dirujuk katalog Geoportal BIG membalas
`HTTP 500 — Service not found`. Metadatanya utuh, layanannya sudah tidak ada.
Tidak ada lapis mana pun yang bisa menolong keadaan ini.

## Versi penyimpanan thumbnail

Thumbnail katalog disimpan di MinIO dengan versi pada prefix. Kunci simpanan
**tidak memuat identitas basemap**, jadi setiap perubahan sumber basemap wajib
menaikkan versi — kalau tidak, seluruh angkatan lama akan terus disajikan
dengan latar yang lama selamanya.

| Prefix | Perubahan |
|--------|-----------|
| `thumb/v1` | PNG |
| `thumb/v2` | WebP |
| `thumb/v3` | latar citra satelit |
| `thumb/v4` | latar topografi |

Setelah upgrade yang menaikkan versi, jalankan pra-render (menu `t` pada
`deploy.sh`) supaya pengunjung pertama tidak menanggung ongkos render, lalu
`prisma/bersihkan-thumbnail.ts --apply` untuk membuang angkatan lama.
