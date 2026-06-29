# Geomdb Hub

Aplikasi web manajemen metadata geospasial berbasis standar **SNI ISO 19115-3 / ISO 19139**. Mendukung input metadata, alur review/penerbitan, QC/QE/QA dengan tanda tangan digital, integrasi layanan GeoServer/ArcGIS, dan katalog publik OGC CSW.

---

## Alur Proses Bisnis

### Peran Pengguna

Sistem menggunakan enam peran (role) dengan hak akses yang berbeda-beda. Setiap akun user memiliki tepat satu peran.

---

#### ADMIN

Pengelola teknis seluruh sistem. Biasanya diisi oleh tim IT.

**Tugas & fungsi:**

- Manajemen pengguna: buat, edit, nonaktifkan, dan hapus akun Walidata
- Konfigurasi global sistem: pengaturan organisasi, SMTP email, WhatsApp, integrasi GeoNode, PKI
- Kelola referensi standar metadata dan halaman dokumentasi/FAQ
- Melihat semua metadata dari semua organisasi tanpa batasan
- Akses penuh ke dashboard analitik & log aktivitas
- Kelola OAuth2 SSO provider

**Rule:**

- Tidak memiliki batasan akses — dapat membaca dan memodifikasi seluruh data di sistem
- Perubahan konfigurasi sensitif (secret, kunci PKI, SMTP password) hanya bisa dilakukan oleh ADMIN
- ADMIN tidak otomatis bisa mereview/mempublish metadata — itu domain WALIDATA; namun secara teknis ADMIN dapat mengubah status record langsung

---

#### WALIDATA

Penanggung jawab data dan kualitas metadata. Merepresentasikan unit walidata yang berwenang.

**Tugas & fungsi:**

- Mendaftarkan referensi organisasi produser data (via bulk import CSV/Excel atau satu per satu); setiap referensi dapat diberi **alias/akronim** yang ditampilkan di card katalog metadata
- Mendaftarkan server geospasial (GeoServer, ArcGIS, CSW) yang dapat digunakan Produsen sebagai sumber import
- Membuat, mengelola, dan **mengimpor massal pengguna dari Excel (.xlsx)** dengan preview validasi per baris — Produsen, Pemeriksa, dan Atasan Pemeriksa dari berbagai instansi
- Mengisi formulir **Quality Assurance (QA)** setelah metadata lolos QC/QE
- Me-review dan memutuskan hasil QA: menyetujui (PUBLISHED) atau menolak (REJECTED) disertai catatan
- Toggle visibilitas metadata yang sudah PUBLISHED menjadi PRIVATE (sementara) dan sebaliknya
- Sinkronisasi metadata ke CSW (pycsw) dan GeoNode setelah penerbitan
- Melihat seluruh metadata dari semua instansi
- Akses dashboard analitik & audit trail

**Rule:**

- Dapat mengelola metadata dari instansi manapun — WALIDATA bersifat lintas organisasi
- Keputusan review (DISETUJUI/DITOLAK) dicatat permanen beserta catatan dan timestamp (tidak bisa dihapus)
- Notifikasi otomatis dikirim ke Produsen setiap kali keputusan review dibuat
- WALIDATA hanya dapat mengelola akun PRODUSEN, PEMERIKSA, dan ATASAN_PEMERIKSA — tidak bisa membuat/mengedit ADMIN atau ATASAN_WALIDATA

---

#### ATASAN_WALIDATA

Pejabat yang bertindak sebagai atasan seluruh Walidata, bersifat lintas-organisasi. Hanya ada **satu akun ATASAN_WALIDATA aktif** di seluruh sistem; dibuat dan dikelola oleh ADMIN saja.

**Tugas & fungsi:**

- Menerima notifikasi email konfirmasi QA dari semua Walidata aktif di seluruh sistem secara otomatis
- Mengakses **Dashboard Antrian QA** (`/atasan-walidata`) — daftar dokumen QA yang menunggu konfirmasi beserta pratinjau detail metadata (abstrak, topik, bbox, batasan)
- Membuka PDF dokumen QA langsung dari dashboard tanpa perlu token terpisah
- Mengonfirmasi atau menolak dokumen QA via link email (satu klik) atau via tombol di dashboard

**Rule:**

- Hanya boleh ada **satu akun ATASAN_WALIDATA aktif** di seluruh sistem — akun kedua diblokir
- Hanya ADMIN yang bisa membuat akun ATASAN_WALIDATA (tidak bisa dibuat via WALIDATA maupun import massal)
- Tidak dapat membuat atau mengubah metadata
- Penolakan oleh ATASAN_WALIDATA mengembalikan metadata ke status REJECTED

---

#### ATASAN_PEMERIKSA

Pejabat yang bertindak sebagai atasan seluruh Pemeriksa dalam satu organisasi. **Wajib ada satu akun ATASAN_PEMERIKSA aktif per organisasi** — jika tidak ada, submit QC/QE oleh Pemeriksa diblokir dengan pesan error hingga akun didaftarkan oleh Admin/Walidata.

**Tugas & fungsi:**

- Menerima notifikasi email konfirmasi QC/QE dari semua Pemeriksa di organisasinya secara otomatis
- Mengakses **Dashboard Antrian Pemeriksaan** (`/atasan-pemeriksa`) — daftar QC/QE yang menunggu konfirmasi beserta pratinjau detail metadata (abstrak, topik, bbox, batasan)
- Membuka PDF dokumen QC/QE langsung dari dashboard tanpa perlu token terpisah
- Mengonfirmasi atau menolak QC/QE via link email atau via dashboard

**Rule:**

- Hanya boleh ada **satu akun ATASAN_PEMERIKSA aktif per organisasi** — akun kedua akan diblokir saat aktivasi
- Semua notifikasi QC/QE dikirim ke akun ATASAN_PEMERIKSA di organisasi yang sama — tidak ada fallback manual per-Pemeriksa
- Jika akun ATASAN_PEMERIKSA dinonaktifkan, Pemeriksa di org tersebut tidak dapat mengajukan QC/QE sampai akun ATASAN_PEMERIKSA baru didaftarkan
- Tidak dapat membuat atau mengubah metadata

---

#### PEMERIKSA

Petugas kualitas data yang bertugas melakukan pemeriksaan QC/QE terhadap metadata yang diajukan Produsen.

**Tugas & fungsi:**

- Melihat metadata dari organisasi sendiri yang sedang dalam tahap pemeriksaan (`QCQE_PROCESS`)
- Melihat dokumen **SPD/KAK/Pedoman** yang dilampirkan Produsen saat submit — tampil sebagai panel hijau di atas pilihan metode pemeriksaan, dapat dibuka langsung di browser
- Memilih satu dari tiga metode pemeriksaan per metadata:
  - **A. Isi Form QC/QE Sistem** — isi formulir **Quality Control (QC)** dan/atau **Quality Evaluation (QE)** secara terstruktur, simpan draft, lalu ajukan ke atasan eselon II; setelah atasan mengkonfirmasi via link email, metadata masuk status REVIEW
  - **B. Upload Dokumen QC/QE (PDF)** — unggah dokumen yang sudah dibuat di luar sistem; dapat memilih QC saja, QE saja, atau QC dan QE sekaligus; metadata langsung masuk REVIEW **tanpa** konfirmasi atasan; dapat pula melampirkan SPD/KAK/Pedoman sebagai referensi tambahan (opsional)
  - **C. Lewati QC/QE/QA** — metadata langsung masuk REVIEW tanpa pemeriksaan; dokumen yang diterbitkan akan menampilkan badge *"Belum QC/QE/QA"*

**Rule:**

- Hanya dapat melihat dan mengisi QC/QE untuk metadata dari **organisasi sendiri**
- Tidak dapat membuat metadata baru atau mengubah isi metadata
- Metode A memerlukan konfirmasi atasan eselon II; metode B dan C tidak memerlukan konfirmasi atasan
- Tidak dapat menyetujui/menolak hasil QA sendiri — itu domain WALIDATA

---

#### PRODUSEN

Pegawai instansi yang bertugas membuat dan mendaftarkan metadata geospasial.

**Tugas & fungsi:**

- Membuat metadata baru secara manual atau via import dari layanan geospasial (GeoServer, ArcGIS, CSW); daftar layer ditampilkan sebagai card grid dengan thumbnail
- Melengkapi isian metadata: judul, abstrak, kata kunci, bounding box, CRS, kontak, distribusi, silsilah, dll.
- Upload thumbnail dan file distribusi
- Mengajukan metadata ke proses pemeriksaan QC/QE — saat submit muncul dialog konfirmasi dengan opsi melampirkan dokumen **SPD/KAK/Pedoman** (PDF, opsional) sebagai referensi bagi Pemeriksa
- Melihat riwayat review dan catatan penolakan dari Walidata
- Mengekspor metadata ke format ISO 19139 XML

**Rule:**

- Dapat melihat dan mengedit metadata dari **organisasi sendiri** — tidak bisa melihat metadata instansi lain
- Tidak dapat mengisi formulir QC/QE — itu domain PEMERIKSA
- Tidak bisa mempublish sendiri; harus melalui proses pemeriksaan (PEMERIKSA) dan review (WALIDATA)
- Metadata yang ditolak (REJECTED) dapat diedit ulang dan diajukan kembali (beserta dokumen SPD baru jika diperlukan)

---

#### Ringkasan Matriks Akses

| Fitur                                  | ADMIN | WALIDATA | ATASAN_WALIDATA | ATASAN_PEMERIKSA | PEMERIKSA | PRODUSEN |
| -------------------------------------- | :---: | :------: | :-------------: | :--------------: | :-------: | :------: |
| Buat metadata                          |   ✓   |    —     |        —        |        —         |     —     |    ✓     |
| Edit metadata                          |   ✓   |    —     |        —        |        —         |     —     |    ✓\*   |
| Lihat metadata semua org               |   ✓   |    ✓     |        —        |        —         |     —     |    —     |
| Ajukan ke pemeriksaan QC/QE            |   ✓   |    —     |        —        |        —         |     —     |    ✓     |
| Lampirkan SPD/KAK/Pedoman saat submit  |   —   |    —     |        —        |        —         |     —     |    ✓     |
| Lihat dokumen SPD/KAK/Pedoman          |   ✓   |    ✓     |        —        |        —         |     ✓     |    ✓\*\* |
| Isi formulir QC/QE                     |   —   |    —     |        —        |        —         |     ✓     |    —     |
| Dashboard Antrian QC/QE                |   —   |    —     |        —        |        ✓         |     —     |    —     |
| Konfirmasi QC/QE (via email/dashboard) |   —   |    —     |        —        |        ✓         |     —     |    —     |
| Lihat PDF QC/QE (org sendiri)          |   ✓   |    ✓     |        —        |        ✓         |     ✓     |    ✓\*\* |
| Isi formulir QA                        |   ✓   |    ✓     |        —        |        —         |     —     |    —     |
| Dashboard Antrian QA                   |   —   |    —     |        ✓        |        —         |     —     |    —     |
| Konfirmasi QA (via email/dashboard)    |   —   |    —     |        ✓        |        —         |     —     |    —     |
| TTE otomatis saat atasan konfirmasi    |   —   |   sistem |      sistem     |      sistem      |   sistem  |    —     |
| Toggle PUBLISHED ↔ PRIVATE             |   ✓   |    ✓     |        —        |        —         |     —     |    —     |
| Kelola referensi organisasi + alias    |   ✓   |    ✓     |        —        |        —         |     —     |    —     |
| Kelola pengguna                        |   ✓   |  ✓\*\*\* |        —        |        —         |     —     |    —     |
| Import pengguna massal Excel           |   ✓   | ✓\*\*\*\*|        —        |        —         |     —     |    —     |
| Konfigurasi sistem                     |   ✓   |    —     |        —        |        —         |     —     |    —     |
| Dashboard analitik                     |   ✓   |    ✓     |        —        |        —         |     —     |    —     |
| Log aktivitas                          |   ✓   |    ✓     |        —        |        —         |     —     |    —     |

> \* PRODUSEN hanya bisa edit metadata dari organisasi sendiri.
> \*\* PRODUSEN hanya dapat melihat dokumen SPD yang mereka sendiri unggah; PDF QC/QE hanya miliknya.
> \*\*\* WALIDATA hanya dapat mengelola akun PRODUSEN, PEMERIKSA, dan ATASAN_PEMERIKSA — tidak bisa membuat/mengedit ADMIN atau ATASAN_WALIDATA.
> \*\*\*\* WALIDATA hanya dapat mengimpor PRODUSEN, PEMERIKSA, dan ATASAN_PEMERIKSA via Excel; WALIDATA dan ATASAN_WALIDATA tidak bisa diimpor massal — hanya dibuat satu per satu oleh ADMIN.

---

### Alur Persiapan (oleh Walidata)

```mermaid
flowchart TD
    W([Walidata])
    W --> A["Tambah Referensi Organisasi<br/>Menu: Pengaturan Org.<br/>Bisa bulk import Excel / CSV<br/>Opsional: tambah alias / akronim"]
    W --> B["Daftarkan Server Geospasial<br/>Menu: Server Geospasial<br/>GeoServer · ArcGIS · CSW"]
    W --> C["Buat Akun Produsen & Pemeriksa<br/>Menu: Pengguna → Tambah Pengguna<br/>Pilihkan organisasi — bisa lintas org"]
    A & B & C --> D([Produsen & Pemeriksa siap login])
```

---

### Alur Lengkap Penerbitan Metadata

```mermaid
flowchart TD
    START([Produsen login]) --> CREATE["Buat / Import metadata"]
    CREATE --> DRAFT[("Status: DRAFT")]
    DRAFT --> EDIT["Edit & lengkapi isian<br/>Simpan draft"]
    EDIT --> SUBMIT["Ajukan ke Pemeriksaan<br/>Klik: Submit ke Pemeriksaan"]
    SUBMIT --> DIALOG["Dialog konfirmasi muncul<br/>Lampirkan SPD/KAK/Pedoman (opsional)"]
    DIALOG --> QCQE[("Status: QCQE_PROCESS")]

    QCQE --> METODE{"Pemeriksa Kualitas<br/>Pilih Metode"}

    METODE -- "A. Isi Form" --> FORM["Isi formulir QC / QE<br/>Simpan draft"]
    FORM --> KIRIM["Kirim ke Atasan Eselon II<br/>Email konfirmasi otomatis"]
    KIRIM --> ATASAN{"Atasan Eselon II<br/>Konfirmasi via link email"}
    ATASAN -- Klik konfirmasi --> REVIEW[("Status: REVIEW")]
    ATASAN -- Tidak merespons --> WAIT["Tunggu konfirmasi"]

    METODE -- "B. Upload PDF" --> UPLOAD["Pilih & upload dokumen<br/>QC saja / QE saja / QC &amp; QE"]
    UPLOAD --> REVIEW

    METODE -- "C. Lewati" --> SKIP["Konfirmasi lewati"]
    SKIP --> REVIEW

    REVIEW --> WLD["Walidata<br/>Isi formulir QA<br/>Ajukan ke Atasan Walidata"]
    WLD --> ATASAN_WLD{"Atasan Walidata<br/>Konfirmasi via link email"}
    ATASAN_WLD -- Konfirmasi --> TTE["Walidata<br/>Tanda Tangan Elektronik (TTE)<br/>PKI Lokal atau BSRE"]
    TTE --> PUB(["Status: PUBLISHED<br/>Sinkron ke CSW & GeoNode"])

    TTE -- Tolak --> REJ(["Status: REJECTED"])
    REJ -.-> EDIT
```

---

### Alur Pembuatan Metadata (Produsen — detail import)

```mermaid
flowchart TD
    START([Produsen login]) --> MENU["Pilih menu: Import dari Layanan"]
    MENU --> SEL["Pilih server yang disediakan Walidata"]
    SEL --> SCAN["Scan server<br/>GeoServer/ArcGIS: WMS · WFS · REST<br/>CSW: GetRecords"]
    SCAN --> CHK{"Layer sudah pernah<br/>diimpor oleh siapapun?"}
    CHK -- Ya --> SKIP["Ditandai 'Sudah Diimpor'<br/>tidak bisa dipilih"]
    CHK -- Belum --> AVAIL["Tersedia untuk dipilih<br/>Tampil card grid + thumbnail"]
    AVAIL --> PICK["Pilih satu atau beberapa layer"]
    PICK --> DETAIL["Load detail otomatis<br/>judul · abstrak · tipe data · kata kunci<br/>bbox · CRS · skala · kontak · distribusi"]
    DETAIL --> PREV["Preview tabel hasil scan"]
    PREV --> CONF["Konfirmasi Import"]
    CONF --> DRAFT[("Draft dibuat per layer")]
    DRAFT --> EDIT["Edit & lengkapi draft jika perlu"]
    EDIT --> SUBMIT["Ajukan ke Pemeriksaan<br/>Status: QCQE_PROCESS"]
```

---

### Alur QC/QE (oleh Pemeriksa)

Pemeriksa memilih satu dari tiga metode untuk setiap metadata yang masuk antrian.

```mermaid
flowchart TD
    QCQE_PROC(["Status: QCQE_PROCESS"]) --> METODE{"Pilih Metode\nPemeriksaan"}

    %% Metode A: Form sistem
    METODE -- "A. Isi Form" --> FORM["Isi formulir QC dan/atau QE"]
    FORM --> QDRAFT["Status QC/QE: DRAFT"]
    QDRAFT --> PEND["Ajukan ke Atasan Eselon II<br/>Status: PENDING_ATASAN"]
    PEND --> EMAIL["Email konfirmasi dikirim ke Atasan"]
    EMAIL --> CONF{"Atasan klik<br/>link konfirmasi"}
    CONF -- Dikonfirmasi --> PA["Status QC/QE: PENDING_APPROVAL"]
    PA --> REVIEW_A(["MetadataRecord → REVIEW"])

    %% Metode B: Upload PDF
    METODE -- "B. Upload PDF" --> STAGE["Pilih file QC dan/atau QE<br/>QC saja · QE saja · QC &amp; QE"]
    STAGE --> KONFIRM["Konfirmasi dokumen<br/>yang akan diunggah"]
    KONFIRM --> REVIEW_B(["MetadataRecord → REVIEW<br/>langsung tanpa konfirmasi atasan"])

    %% Metode C: Lewati
    METODE -- "C. Lewati" --> SKIP["Konfirmasi lewati QC/QE/QA"]
    SKIP --> REVIEW_C(["MetadataRecord → REVIEW<br/>badge: Belum QC/QE/QA"])

    %% Konvergensi ke Walidata
    REVIEW_A & REVIEW_B & REVIEW_C --> WALIDATA["Walidata isi QA & TTE"]
    WALIDATA --> MTD{"Metode<br/>tanda tangan"}
    MTD -- PKI Lokal --> PKI["Sertifikat PKCS12<br/>milik instansi"]
    MTD -- BSRE --> BSRE["Balai Sertifikasi Elektronik<br/>BSSN"]
    PKI & BSRE --> SIGNED(["QA SIGNED<br/>Metadata → PUBLISHED<br/>PDF tersimpan di MinIO"])
```

---

### Visibilitas Data

```mermaid
flowchart LR
    subgraph Dashboard ["Dashboard Metadata"]
        P1["PRODUSEN / PEMERIKSA<br/>Hanya data organisasi sendiri<br/>DRAFT · QCQE_PROCESS · REVIEW · PUBLISHED · REJECTED"]
        WA["WALIDATA / ADMIN<br/>Semua data semua organisasi"]
    end
    subgraph Katalog ["Katalog Publik /katalog"]
        PUB["Semua orang<br/>Hanya metadata PUBLISHED<br/>dari semua organisasi"]
    end
```

---

### Status Metadata — Siklus Hidup

```mermaid
stateDiagram-v2
    [*] --> DRAFT : Buat metadata baru

    DRAFT --> QCQE_PROCESS : Produsen submit</br>"Submit ke Pemeriksaan"</br>(+ lampirkan SPD opsional)
    REJECTED --> DRAFT : Produsen edit ulang
    REJECTED --> QCQE_PROCESS : Produsen submit ulang</br>(+ lampirkan SPD baru opsional)

    QCQE_PROCESS --> REVIEW : Pemeriksa isi QC/QE</br>Atasan eselon II konfirmasi

    REVIEW --> PUBLISHED : Walidata isi QA</br>Tanda tangan elektronik
    REVIEW --> REJECTED : Walidata tolak

    PUBLISHED --> PRIVATE : Walidata sembunyikan
    PRIVATE --> PUBLISHED : Walidata publikasi ulang
```

| Status         | Keterangan                                                         | Siapa yang dapat mengubah              |
| -------------- | ------------------------------------------------------------------ | -------------------------------------- |
| `DRAFT`        | Baru dibuat / ditolak, sedang dilengkapi                           | Produsen (dapat lampirkan SPD saat submit) |
| `QCQE_PROCESS` | Dalam proses pemeriksaan QC/QE oleh Pemeriksa; SPD dari Produsen dapat dilihat Pemeriksa | — (otomatis saat submit) |
| `REVIEW`       | Pemeriksaan selesai, menunggu tinjauan Walidata                    | — (otomatis: via konfirmasi atasan, upload PDF, atau lewati) |
| `PUBLISHED`    | Disetujui Walidata & QA ditandatangani, tersedia di katalog publik | Walidata (publish/private)             |
| `PRIVATE`      | Sementara disembunyikan dari katalog publik                        | Walidata                               |
| `REJECTED`     | Ditolak Walidata, dapat diajukan ulang                             | Produsen (edit → submit ulang)         |

---

### Atasan Pemeriksa

Email konfirmasi QC/QE selalu dikirim ke akun **ATASAN_PEMERIKSA** aktif di organisasi yang sama dengan Pemeriksa. Tidak ada fallback lain — jika tidak ada akun ATASAN_PEMERIKSA aktif di org tersebut, submit QC/QE diblokir sampai akun didaftarkan.

---

### Mode Alur Konfirmasi Atasan (STRICT / PARALEL)

Walidata dapat memilih dua mode alur konfirmasi atasan di **Pengaturan Org. → Alur QC/QE**:

| Mode | Deskripsi |
| ---- | --------- |
| **Mode Ketat (STRICT)** | Konfirmasi atasan **wajib** sebelum proses lanjut. MetadataRecord tidak berubah status sampai atasan mengklik link konfirmasi di email. Memerlukan email aktif. |
| **Mode Paralel (PARALEL)** | Konfirmasi atasan berjalan **bersamaan** — tidak memblokir proses. MetadataRecord langsung dipublish saat Walidata submit QA; TTE bisa dilakukan sambil menunggu konfirmasi atasan. Cocok jika email belum dikonfigurasi. |

> **Default:** STRICT. Ubah ke PARALEL jika ingin alur yang lebih cepat atau jika email belum siap.

### Status Dokumen QC/QE/QA — Siklus Hidup

```mermaid
stateDiagram-v2
    [*] --> DRAFT : Pemeriksa / Walidata isi formulir

    DRAFT --> PENDING_ATASAN : Mode STRICT — Ajukan ke Atasan</br>(kirim email konfirmasi, memblokir)
    DRAFT --> PENDING_APPROVAL : Mode PARALEL — Ajukan ke Atasan</br>(email informasional, tidak memblokir)
    PENDING_ATASAN --> PENDING_APPROVAL : Atasan klik konfirmasi</br>di link email
    PENDING_APPROVAL --> DRAFT : Walidata tolak
    PENDING_APPROVAL --> SIGNED : Walidata setujui &</br>Tanda Tangan Elektronik

    SIGNED --> [*] : Dokumen final</br>PDF tersimpan di MinIO
```

| Status             | Keterangan                                                                      |
| ------------------ | ------------------------------------------------------------------------------- |
| `DRAFT`            | Baru diisi / dikembalikan setelah ditolak                                       |
| `PENDING_ATASAN`   | (Mode STRICT) Menunggu konfirmasi atasan eselon II via link email — memblokir TTE |
| `PENDING_APPROVAL` | Atasan sudah konfirmasi (STRICT) **atau** langsung masuk (PARALEL) — siap TTE  |
| `SIGNED`           | Ditandatangani secara elektronik, final                                         |

Jika email konfirmasi tidak diterima atasan, Walidata/Pemeriksa dapat mengirim ulang via tombol **Kirim Ulang** di halaman detail metadata (selama status masih `PENDING_ATASAN` atau `PENDING_APPROVAL` tanpa konfirmasi).

---

### Notifikasi Otomatis

Setiap perubahan status memicu notifikasi:

- **In-app** — ikon notifikasi di topbar, real-time polling
- **Email** — via SMTP (konfigurasi per organisasi)
- **WhatsApp** — via whatsapp-web.js (opsional, aktifkan di pengaturan organisasi)

| Peristiwa                             | Penerima                              |
| ------------------------------------- | ------------------------------------- |
| Metadata diajukan ke pemeriksaan      | (log aktivitas)                       |
| QC/QE menunggu konfirmasi atasan      | Atasan Eselon II / ATASAN_PEMERIKSA (email) |
| Metadata masuk status REVIEW          | Semua Walidata aktif (email + in-app) |
| Walidata ajukan QA ke Atasan Walidata | ATASAN_WALIDATA (email)               |
| QA disetujui / ditolak                | Produsen (email + WA + in-app)        |
| Metadata disetujui / ditolak Walidata | Produsen (email + in-app)             |

---

## Tech Stack

### Frontend

| Teknologi                | Versi  | Keterangan                                      |
| ------------------------ | ------ | ----------------------------------------------- |
| Next.js                  | 16.2   | App Router, RSC, server actions                 |
| React                    | 19     |                                                 |
| TypeScript               | 5      | Strict mode                                     |
| Tailwind CSS             | 4      |                                                 |
| Radix UI                 | —      | Komponen aksesibel (dialog, select, tabs, dll.) |
| Framer Motion            | 12     | Animasi UI                                      |
| MapLibre GL / OpenLayers | 5 / 10 | Peta & bounding box picker                      |
| React Hook Form + Zod    | —      | Form & validasi                                 |
| @react-pdf/renderer      | 4      | Generate PDF laporan QC/QE                      |
| Recharts                 | 3.8    | Chart & grafik dashboard analitik               |

### Backend

| Teknologi            | Versi    | Keterangan                                   |
| -------------------- | -------- | -------------------------------------------- |
| Next.js API Routes   | 16.2     | REST API internal                            |
| Prisma ORM           | 7        | Query builder + schema management            |
| PostgreSQL + PostGIS | 16 + 3.4 | Database utama + ekstensi spasial            |
| Redis                | 7        | Cache CSW & session                          |
| MinIO                | latest   | Object storage (PDF tanda tangan, thumbnail, SPD/KAK/Pedoman) |
| pycsw                | 2.6.1    | OGC CSW 2.0.2 catalogue server               |
| jose                 | 6        | JWE session token (AES-256-GCM)              |
| Saxon-JS             | 2        | XSLT transform (ekspor ISO XML)              |
| pdf-lib + node-forge | —        | Manipulasi & signing PDF                     |

### Keamanan

| Mekanisme              | Keterangan                                                                    |
| ---------------------- | ----------------------------------------------------------------------------- |
| JWE session            | AES-256-GCM, maks 7 hari (idle timeout 1 hari), di-blacklist saat logout/ganti password/ganti email; blacklist TTL 7 hari |
| Field-level encryption | Email dan telepon disimpan AES-256-GCM di DB; `ENCRYPTION_KEY` wajib 64-char hex (fail-closed — non-hex throw); migration-safe via `decryptOptional()` |
| Email lookup           | HMAC-SHA256 deterministik (`emailHash`) — bukan plaintext                     |
| CSRF protection        | Origin header check (primer) + Referer fallback (sekunder) untuk semua mutating request; fail-closed — request tanpa origin/referer yang dikenal langsung ditolak |
| PoW Captcha            | Proof-of-Work SHA-256 (difficulty 4) sebelum submit login — cegah bot/brute force; challenge single-use disimpan di Redis 5 menit |
| Rate limiting          | Redis atomic `SET NX EX` di semua endpoint sensitif: login, OTP verify (10 req/15 menit per IP), reset password (10 req/15 menit per IP), PDF token, antrian atasan, backup, konfirmasi token, bulk import pengguna, ArcGIS login relay (5 req/menit per IP) |
| Input validation       | Zod v4 di semua POST/PATCH/PUT endpoint; XML import menolak `<!DOCTYPE` / `<!ENTITY` sebelum parsing (cegah XXE) |
| IDOR protection        | PDF QC/QE hanya dapat diakses oleh org yang sama (PEMERIKSA/ATASAN_PEMERIKSA) atau pemilik (PRODUSEN); WALIDATA/ADMIN bersifat lintas-org; WALIDATA tidak bisa mengedit pengguna dari org lain |
| SSRF guard             | `safeFetch()` dengan `redirect:'manual'`, validasi per-hop, blokir IPv4/IPv6 private + link-local |
| SVG upload             | Magic bytes validation + CSP sandbox + `Content-Disposition: attachment` — cegah stored XSS |
| OTP login              | Kode 6-digit via email/WhatsApp, opsional (default: nonaktif pada fresh install); perbandingan hash menggunakan `timingSafeEqual` — cegah timing attack; HMAC key fail-closed — `APP_SECRET` atau `JWT_SECRET` wajib diset |
| Security headers       | CSP nonce per-request (tanpa `'unsafe-inline'`), HSTS (2 tahun), X-Frame-Options, Referrer-Policy, Permissions-Policy |
| Idle session           | Logout otomatis setelah 1 hari tidak aktif (Redis idle key) |

### Infrastruktur

| Komponen                | Keterangan                                                       |
| ----------------------- | ---------------------------------------------------------------- |
| Docker + Docker Compose | Orkestrasi semua layanan                                         |
| Nginx 1.27              | Reverse proxy, SSL termination                                   |
| Certbot                 | Let's Encrypt otomatis, atau sertifikat komersial                |
| ext-serv                | Microservice internal: email (SMTP) + WhatsApp (whatsapp-web.js) |

---

## Spesifikasi Server yang Direkomendasikan

### Minimum (tanpa WhatsApp)

| Komponen | Spesifikasi                  |
| -------- | ---------------------------- |
| CPU      | 2 vCPU                       |
| RAM      | 4 GB                         |
| Storage  | 40 GB SSD                    |
| OS       | Ubuntu 22.04 LTS / Debian 12 |

### Rekomendasi (dengan WhatsApp aktif)

| Komponen | Spesifikasi                                        |
| -------- | -------------------------------------------------- |
| CPU      | 4 vCPU                                             |
| RAM      | **8 GB** (ext-serv/Chromium butuh ~1–2 GB sendiri) |
| Storage  | 80 GB SSD                                          |
| OS       | Ubuntu 22.04 LTS / Debian 12                       |

> **Catatan:** ext-serv menjalankan Chromium headless untuk WhatsApp Web, sehingga membutuhkan shared memory (`shm_size: 512mb`) dan capability `SYS_ADMIN`. Jika WhatsApp tidak dibutuhkan, set `WA_ENABLED=false` untuk menonaktifkan Chromium dan menghemat memori.

### Port yang dibuka di firewall

| Port | Keterangan               |
| ---- | ------------------------ |
| 80   | HTTP (redirect ke HTTPS) |
| 443  | HTTPS                    |
| 22   | SSH                      |

Port internal (3000, 5432, 6379, 9000, 9001, 8080, 3007) **tidak perlu** dibuka ke publik — diakses oleh Nginx dan antar-container via Docker network.

---

## Deploy (Production)

### Prasyarat

- Docker Engine 24+ dan Docker Compose V2
- Domain yang sudah mengarah ke IP server
- Akses SSH ke server

### 1. Clone repository

```bash
git clone <repo-url> geomdb-hub
cd geomdb-hub
```

### 2. Konfigurasi environment via wizard deploy.sh

Jalankan wizard interaktif — tidak perlu menyalin `.env.example` secara manual:

```bash
bash deploy.sh
```

Wizard akan menanyakan secara bertahap:

| Pertanyaan                   | Contoh Jawaban                                |
| ---------------------------- | --------------------------------------------- |
| Domain aplikasi              | `metadata.example.id`                         |
| Base path (kosong jika root) | `/geomdb-hub` atau kosong                     |
| URL CSW publik               | `https://metadata.example.id/csw`             |
| Port-port layanan            | Enter untuk default semua                     |
| Subnet Docker                | auto-detect, atau isi manual                  |
| Network GeoNode              | `geonode_default` atau kosong jika standalone |
| Cara install image           | build lokal / pull dari registry CI           |
| Variabel rahasia             | JWT_SECRET, APP_SECRET, password, dll.        |

Setelah wizard selesai, file `.env` otomatis terbuat. Wizard juga menangani `docker login` ke registry GitLab jika Anda memilih opsi pull dari CI.

Variabel yang **wajib** diisi wizard:

| Variabel              | Keterangan                                                                |
| --------------------- | ------------------------------------------------------------------------- |
| `JWT_SECRET`          | Kunci signing JWT sesi (di-generate otomatis jika dikosongkan)            |
| `APP_SECRET`          | Kunci enkripsi data sensitif (di-generate otomatis jika dikosongkan)      |
| `ENCRYPTION_KEY`      | Kunci AES-256 field-level encryption email/telepon (di-generate otomatis) |
| `POSTGRES_PASSWORD`   | Password database PostgreSQL, minimal 16 karakter                         |
| `REDIS_PASSWORD`      | Password Redis (di-generate otomatis)                                     |
| `MINIO_ROOT_PASSWORD` | Password MinIO, minimal 8 karakter                                        |
| `EXT_SERV_API_KEY`    | API key komunikasi app ↔ ext-serv                                         |
| `SEED_ADMIN_EMAIL`    | Email akun admin pertama                                                  |
| `SEED_ADMIN_PASSWORD` | Password akun admin pertama                                               |
| `NEXT_PUBLIC_APP_URL` | URL publik aplikasi, misal `https://metadata.example.id`                  |

### 3. Siapkan SSL

**Opsi A — Let's Encrypt (otomatis, gratis):**

```bash
npm run ssl:certbot
# Ikuti instruksi, masukkan domain dan email
```

**Opsi B — Sertifikat komersial:**

```bash
npm run ssl:install
# Ikuti instruksi, letakkan file .crt dan .key
```

**Opsi C — Self-signed (hanya untuk testing internal):**

```bash
npm run ssl:generate
```

### 4. Jalankan semua layanan

```bash
docker compose up -d
```

Docker akan otomatis:

1. Menjalankan PostgreSQL, Redis, MinIO, pycsw, dan ext-serv
2. Build image Next.js (mungkin 3–5 menit pertama kali)
3. Menjalankan migrasi database dan seed data awal
4. Menjalankan aplikasi di belakang Nginx

> **Fresh install — Login pertama:** OTP login **nonaktif secara default**. Admin dapat langsung masuk dengan email + password tanpa perlu konfigurasi SMTP terlebih dahulu. Setelah masuk, aktifkan OTP dan konfigurasikan SMTP di **Pengaturan Org. → Email**.

### 5. Verifikasi

```bash
# Status semua container
docker compose ps

# Cek health aplikasi
curl https://yourdomain.com/api/ping

# Atau buka dashboard status
https://yourdomain.com/admin/status
```

### Update aplikasi

**Tanpa CI (build di server — lambat):**

```bash
git pull
docker compose up -d --build app migrate ext-serv
```

**Dengan CI (pull image dari registry — cepat, direkomendasikan):**

```bash
docker compose pull migrate app ext-serv
docker compose up -d
```

> Image sudah dibangun otomatis oleh GitLab CI setiap push ke `main` / `development`.
> Lihat seksi [GitLab CI Pipeline](#gitlab-ci-pipeline-opsional) untuk setup awal.

---

## Format Input yang Disarankan

### Nomor Telepon / WhatsApp

| Konteks                   | Format yang Diterima                        | Contoh                         |
| ------------------------- | ------------------------------------------- | ------------------------------ |
| WA OTP & notifikasi       | Nomor HP Indonesia diawali `08`             | `081234567890`                 |
| WA OTP & notifikasi       | Format internasional tanpa `+`              | `6281234567890`                |
| WA OTP & notifikasi       | Format internasional dengan `+`             | `+6281234567890`               |
| Telepon kantor (metadata) | Bebas format, termasuk spasi & tanda kurung | `(021) 5678-901` / `021-56789` |

> **Penting:** Nomor telepon kantor/PSTN (diawali `021`, `022`, `031`, dll.) **tidak dapat menerima WhatsApp**. Untuk fitur WA OTP, gunakan nomor HP aktif yang bisa dipindai QR WhatsApp-nya. Sistem akan otomatis mengonversi `08x` → `628x` saat mengirim.

### Koordinat Bounding Box (BBOX)

| Field                         | Rentang Valid    | Contoh (Jawa Barat) |
| ----------------------------- | ---------------- | ------------------- |
| Batas Utara (`bboxUtara`)     | `-90` s/d `90`   | `-6.75`             |
| Batas Selatan (`bboxSelatan`) | `-90` s/d `90`   | `-7.82`             |
| Batas Timur (`bboxTimur`)     | `-180` s/d `180` | `108.80`            |
| Batas Barat (`bboxBarat`)     | `-180` s/d `180` | `106.35`            |

> Gunakan desimal dengan titik (`.`), bukan koma. Selatan dan Barat biasanya bernilai negatif untuk wilayah Indonesia.

### Tanggal

| Field                       | Format       | Contoh       |
| --------------------------- | ------------ | ------------ |
| Tanggal Publikasi           | `YYYY-MM-DD` | `2024-01-15` |
| Tanggal Revisi              | `YYYY-MM-DD` | `2024-06-30` |
| Rentang Waktu (Mulai/Akhir) | `YYYY-MM-DD` | `2023-01-01` |

### Email

Standar RFC 5321: `nama@domain.tld`. Untuk email organisasi pemerintah: `nama@instansi.go.id`.

### URL / Website

Harus diawali `http://` atau `https://`. Contoh: `https://www.big.go.id`.

### File Identifier / UUID

Isian opsional — jika dikosongkan, sistem generate UUID otomatis. Jika diisi, harus unik di seluruh sistem. Format UUID: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.

---

## Fitur Publik

Fitur berikut dapat diakses **tanpa login** melalui browser.

### Standar (/standar)

Halaman referensi standar metadata geospasial yang digunakan dalam sistem. Seed awal berisi 10 standar:

| Kode                    | Judul                                                  | Kategori            |
| ----------------------- | ------------------------------------------------------ | ------------------- |
| SNI ISO 19115-1:2014    | Metadata — Dasar-dasar                                 | Metadata Geospasial |
| SNI ISO 19115-3:2016    | Metadata — Implementasi XML (format ekspor utama JIGN) | Metadata Geospasial |
| ISO 19115-3:2018        | Metadata — XML (amandemen, format ekspor alternatif)   | Metadata Geospasial |
| ISO 19139:2007          | Metadata — GMD (kompatibilitas sistem lama)            | Metadata Geospasial |
| ISO 19157:2013          | Kualitas Data (QC/QE/QA)                               | Kualitas Data       |
| ISO 19111:2019          | Referensi Koordinat (CRS, EPSG)                        | Referensi Spasial   |
| ISO 19108:2002          | Temporal Schema                                        | Referensi Spasial   |
| OGC CSW 2.0.2           | Catalogue Service for the Web                          | Layanan Data        |
| OGC Filter Encoding 1.1 | Filter XML untuk GetRecords                            | Layanan Data        |
| Dublin Core 1.1         | Output schema default CSW                              | Metadata Geospasial |

Admin dapat menambah, mengedit urutan, atau menonaktifkan standar dari halaman **Admin → Standar**.

### Dokumentasi (/dokumentasi)

Hub dokumentasi dengan dua kategori:

- **Panduan** (10 halaman) — cara menggunakan sistem: pengenalan, registrasi, membuat metadata, identifikasi & kata kunci, cakupan spasial/temporal, kualitas & silsilah, distribusi & layanan, publikasi & ekspor, QC/QE/QA, dan katalog publik & CSW.
- **API** (3 halaman) — referensi teknis: pengenalan API, endpoint REST publik, dan endpoint OGC CSW.

Konten ditulis dalam format Markdown dan di-render di sisi klien. Admin mengelola halaman dari **Admin → Dokumentasi**.

### FAQ (/dokumentasi/faq)

Halaman tanya jawab umum dalam format accordion. Seed awal berisi 12 pertanyaan yang mencakup: login, pengajuan metadata, publikasi, koordinat BBOX, ekspor XML/XSLT, upload QC, katalog, CSW, import GeoNode, PKI, dan email SMTP.

Admin mengelola item FAQ dari **Admin → Dokumentasi → FAQ**.

---

## GitLab CI Pipeline (Opsional)

Pipeline otomatis membangun image Docker dan mendorongnya ke **GitLab Container Registry** setiap kali ada push ke branch `main` atau `development`. Server tidak perlu build sama sekali — cukup `docker compose pull`.

### Cara Kerja

```
Push ke GitLab → CI Runner build 3 image → Push ke registry
                                                    ↓
                                    Server: docker compose pull → up -d
```

Layer build di-cache dari image sebelumnya (`--cache-from`), sehingga build kedua dan seterusnya jauh lebih cepat (hanya layer yang berubah yang direbuild).

### Setup (sekali saja)

**1. Variabel CI** — GitLab → Settings → CI/CD → Variables:

| Variable                | Contoh                          | Keterangan                             |
| ----------------------- | ------------------------------- | -------------------------------------- |
| `NEXT_PUBLIC_APP_URL`   | `https://geomdb.example.id`     | URL publik aplikasi                    |
| `NEXT_PUBLIC_BASE_PATH` | `/geomdb-hub`                   | Sub-path jika ada, kosongkan jika root |
| `NEXT_PUBLIC_PYCSW_URL` | `https://geomdb.example.id/csw` | URL publik CSW                         |
| `WA_ENABLED`            | `true`                          | Aktifkan WhatsApp (opsional)           |

**2. Login registry di server** (sekali saja):

```bash
# Buat Personal Access Token di GitLab → Profile → Access Tokens (scope: read_registry)
docker login registry.gitlab.com -u <username> -p <token>
```

**3. Nama image di registry:**

```
registry.gitlab.com/harihk1/geomdb-hub/app-standalone
registry.gitlab.com/harihk1/geomdb-hub/migrate
registry.gitlab.com/harihk1/geomdb-hub/ext-serv
```

Wizard `deploy.sh` (opsi registry) mengisi variabel `GEOMDB_APP_IMAGE`, `GEOMDB_MIGRATE_IMAGE`, dan `GEOMDB_EXT_SERV_IMAGE` secara otomatis dan menjalankan `docker login` sebelum pull.

> Tanpa variabel image tersebut, `docker compose` tetap build lokal (backward-compatible).

---

## Integrasi GeoNode

Jika geomdb-hub dijalankan bersama GeoNode di server yang sama, tambahkan konfigurasi berikut agar nginx GeoNode dapat meneruskan request ke container `geomdb_app`.

### 1. Docker network bersama

Wizard `deploy.sh` menanyakan nama network GeoNode (`GEONODE_NETWORK`, default: `geonode_default`). Nilai ini ditulis ke `.env` dan digunakan `docker-compose.yml` sebagai external network `share_network`:

```yaml
networks:
  share_network:
    external: true
    name: ${GEONODE_NETWORK:-geonode_default}
```

Service `app` otomatis bergabung ke kedua network sehingga container `geomdb_app` dapat dijangkau **by name** dari nginx GeoNode.

### 2. Konfigurasi nginx GeoNode

Tambahkan location block berikut ke nginx GeoNode (biasanya `nginx/nginx.conf` di repo GeoNode):

```nginx
location /geomdb-hub/ {
    proxy_pass http://geomdb_app:3000/geomdb-hub/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Sesuaikan `/geomdb-hub/` dengan nilai `NEXT_PUBLIC_BASE_PATH` di `.env` Anda.

#### (Opsional) Hardening CSP — hapus `script-src 'unsafe-inline'`

Aplikasi default mengirim CSP statis ber-`'unsafe-inline'` (akar: halaman Next
di-prerender statis → nonce tak bisa ditempel di app). Untuk menaikkan skor VA,
nginx GeoNode bisa **menstempel nonce per-request** ke setiap `<script>` sehingga
`'unsafe-inline'` dapat dihapus. Ganti location di atas dengan:

```nginx
# Pengecualian PDF QC/QE (boleh di-iframe internal) — taruh DI ATAS /geomdb-hub/
location ~ ^/geomdb-hub/api/metadata/[^/]+/qcqe/pdf$ {
    proxy_pass http://geomdb_app:3000;
    proxy_set_header Host $host;
    proxy_hide_header Content-Security-Policy;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; object-src 'none'; frame-ancestors 'self'" always;
}

# Dokumen PDF (QC/QE + SPD/KAK/Pedoman) — boleh di-embed iframe internal.
# Regex diprioritaskan di atas prefix /geomdb-hub/. frame-ancestors 'self'
# menggantikan 'none' agar preview PDF di halaman Pemeriksa & Walidata tak terblokir.
# (Sesuaikan port upstream dengan punya Anda — mis. 3000/3001.)
location ~ ^/geomdb-hub/api/metadata/[^/]+/(qcqe/pdf|pemeriksa/spd)$ {
    proxy_pass http://geomdb_app:3000;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_hide_header Content-Security-Policy;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; object-src 'none'; frame-ancestors 'self'; upgrade-insecure-requests" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
}

location /geomdb-hub/ {
    # Blok probe Server Action (app tak memakai Server Action — semua via /api/*).
    # Cegah error log "Failed to find Server Action". HAPUS jika mulai pakai Server Action.
    if ($http_next_action) { return 400; }

    proxy_pass http://geomdb_app:3000/geomdb-hub/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # CSP nonce: $request_id = nonce acak per-request
    proxy_hide_header Content-Security-Policy;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'nonce-$request_id' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; font-src 'self' data:; connect-src 'self' wss:; worker-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests" always;
    # add_header di location menggugurkan add_header parent → re-deklarasi yang penting:
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    # sub_filter butuh respons tak ter-kompres dari upstream
    proxy_set_header Accept-Encoding "";
    sub_filter_once  off;
    sub_filter_types text/html;
    sub_filter '<script' '<script nonce="$request_id"';
}
```

**Catatan:** `style-src 'unsafe-inline'` tetap (atribut `style={}` tak bisa di-nonce);
pastikan `gzip on` di nginx GeoNode; wajib `nginx -t` + smoke test login & preview PDF.

### 3. Verifikasi

```bash
# Dari dalam container nginx GeoNode
docker exec geonode_nginx curl -I http://geomdb_app:3000/geomdb-hub/api/ping
# Harus mengembalikan HTTP 200
```

---

## Pengembangan Lokal (Developer)

### Prasyarat

- Node.js 20+
- Docker Desktop (untuk menjalankan infrastruktur)

### 1. Clone dan install dependensi

```bash
git clone <repo-url> geomdb-hub
cd geomdb-hub
npm install
```

### 2. Konfigurasi environment

```bash
cp .env.example .env
```

Isi minimal untuk lokal:

```env
DATABASE_URL="postgresql://geomdb:password@localhost:5432/geomdb_hub"
REDIS_URL="redis://localhost:6379"
MINIO_URL="http://localhost:9000"
JWT_SECRET="dev-secret-ganti-di-production"
APP_SECRET="dev-secret-ganti-di-production"
ENCRYPTION_KEY="dev-encryption-key-ganti-di-production"
POSTGRES_PASSWORD="password"
MINIO_ROOT_PASSWORD="password123"
EXT_SERV_API_KEY="dev-ext-serv-key"
SEED_ADMIN_EMAIL="admin@example.com"
SEED_ADMIN_PASSWORD="Admin1234!"
NEXT_PUBLIC_APP_URL="http://localhost:3000"
```

### 3. Jalankan infrastruktur via Docker

```bash
npm run docker:dev
# setara dengan: docker compose up -d postgres redis minio pycsw
```

### 4. Setup database dan seed

```bash
npm run setup
# setara dengan: prisma db push && tsx prisma/seed.ts
```

### 5. Jalankan dev server

```bash
npm run dev
```

Buka `http://localhost:3000` — login dengan email dan password dari `SEED_ADMIN_EMAIL` / `SEED_ADMIN_PASSWORD`.

### Perintah development berguna

```bash
npm run db:studio          # Buka Prisma Studio (GUI database)
npm run db:push            # Apply perubahan schema ke DB
npm run db:seed            # Jalankan seed ulang
npm run db:reset           # Reset DB + seed ulang (hapus semua data!)
npm run db:generate        # Generate Prisma client setelah edit schema

npm run docker:logs        # Lihat log postgres/redis/minio/pycsw
npm run docker:down        # Stop semua container infrastruktur
```

---

## Arsitektur Layanan

```mermaid
flowchart TD
    Internet(["Internet"]) --> NGX["Nginx :80 / :443<br/>SSL termination · Reverse proxy"]
    NGX --> APP["Next.js App :3000<br/>Antarmuka & REST API"]
    APP --> PG[("PostgreSQL :5432<br/>Database + FTS")]
    APP --> RDS[("Redis :6379<br/>Cache · Session")]
    APP --> MIO[("MinIO :9000<br/>Object storage<br/>PDF · Thumbnail")]
    APP --> CSW["pycsw :8080<br/>OGC CSW 2.0.2"]
    APP --> EXT["ext-serv :3007<br/>Email SMTP<br/>WhatsApp"]
```

| Service    | Port Default | Keterangan                       |
| ---------- | ------------ | -------------------------------- |
| `nginx`    | 80 / 443     | Reverse proxy & SSL              |
| `app`      | 3000         | Next.js — antarmuka utama        |
| `postgres` | 5432         | PostgreSQL 16 + PostGIS 3.4      |
| `redis`    | 6379         | Cache & session                  |
| `minio`    | 9000 / 9001  | Object storage (API / Console)   |
| `pycsw`    | 8080         | OGC CSW catalogue                |
| `ext-serv` | 3007         | Notifikasi email + WhatsApp      |
| `migrate`  | —            | One-shot: migrasi DB saat deploy |

### Urutan Startup (otomatis)

```mermaid
flowchart LR
    PG(["postgres<br/>(healthy)"])
    RDS(["redis<br/>(healthy)"])
    MIO(["minio<br/>(healthy)"])
    EXT(["ext-serv<br/>(healthy)"])
    MIG["migrate<br/>(selesai)"]
    APP["app"]
    NGX["nginx"]
    CSW["pycsw"]
    PG --> MIG
    PG --> CSW
    RDS --> MIG
    MIO --> MIG
    EXT --> MIG
    MIG --> APP --> NGX
```

Aplikasi tidak akan start sebelum semua dependensi siap dan migrasi selesai.

---

## Perintah Docker Berguna

```bash
# Status semua container
docker compose ps

# Log semua container
docker compose logs -f

# Log container tertentu
docker compose logs -f app
docker compose logs -f ext-serv

# Restart satu service
docker compose restart app

# Stop semua (data tetap)
docker compose down

# Stop dan hapus semua data — HATI-HATI!
docker compose down -v

# Rebuild image app setelah perubahan kode
docker compose up -d --build app
```

---

## Backup & Recovery

### Backup Metadata via UI (Admin)

ADMIN dapat mengunduh backup metadata langsung dari browser melalui halaman `/admin/backup`:

1. Pilih satu atau banyak record (atau centang "Pilih Semua")
2. Pilih konten yang ingin diikutsertakan: **Metadata JSON**, **XML (ISO 19139 + ISO 19115-3)**, **File Dokumen (PDF)**
3. Klik **Download ZIP**

Fitur tambahan di halaman backup:
- **Tombol Detail** — lihat isian metadata lengkap + status dokumen QC/QE/QA tanpa perlu record berstatus PUBLISHED
- **Filter** kolom Instansi, Tipe Data, Status
- **Pencarian** judul & organisasi

### Strategi Backup

| Data | Lokasi | Frekuensi Rekomendasi |
| ---- | ------ | --------------------- |
| Database PostgreSQL | Volume Docker `postgres_data` | Harian (otomatis via cron) |
| File PDF QC/QE/QA | MinIO bucket `geomdb-hub` | Mingguan (sync ke storage eksternal) |
| Konfigurasi `.env` | Server filesystem | Setiap perubahan konfigurasi |
| Sertifikat PKI sistem | `SYSTEM_CERT_P12_PATH` | Saat perpanjangan sertifikat |

### Backup Database (Harian)

```bash
# Dump database ke file terkompresi
docker exec geomdb_postgres pg_dump -U geomdb geomdb_hub | gzip \
  > /backup/geomdb_hub_$(date +%Y%m%d_%H%M%S).sql.gz

# Rekomendasi: tambahkan ke crontab
# 0 2 * * * docker exec geomdb_postgres pg_dump -U geomdb geomdb_hub | gzip > /backup/geomdb_hub_$(date +%Y%m%d).sql.gz
```

### Backup MinIO (File PDF)

```bash
# Sinkronisasi bucket ke direktori lokal (perlu mc/MinIO Client)
mc alias set geomdb http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
mc mirror geomdb/geomdb-hub /backup/minio/geomdb-hub/
```

### Restore Database

```bash
# Restore dari dump
gunzip -c /backup/geomdb_hub_YYYYMMDD.sql.gz | \
  docker exec -i geomdb_postgres psql -U geomdb geomdb_hub
```

### Recovery Checklist

Jika terjadi insiden:
1. Stop container aplikasi: `docker compose stop app`
2. Restore database dari dump terakhir
3. Restore file MinIO jika ada file yang hilang
4. Verifikasi integritas: `curl https://yourdomain.com/api/ping`
5. Start aplikasi: `docker compose start app`
6. Cek log: `docker compose logs -f app`

---

## Keamanan Deployment

### Konfigurasi Nginx — Trusted Proxy

Agar rate limiting dan IP tracking berjalan benar, Nginx **wajib** meneruskan IP klien yang asli. Tambahkan konfigurasi berikut di block `server` Nginx:

```nginx
# Percayai IP dari Docker internal network saja
set_real_ip_from  172.16.0.0/12;   # Docker default subnet
set_real_ip_from  10.0.0.0/8;      # Custom subnet jika diubah
real_ip_header    X-Forwarded-For;
real_ip_recursive on;

location /geomdb-hub/ {
    proxy_pass http://geomdb_app:3000/geomdb-hub/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

> **Penting:** Tanpa `set_real_ip_from`, header `X-Forwarded-For` bisa di-spoof oleh klien, sehingga rate limiting per-IP tidak efektif.

### Auto-TTE (Opsional)

Untuk mengaktifkan tanda tangan elektronik otomatis saat atasan mengkonfirmasi:

```bash
# Tambahkan ke .env
SYSTEM_CERT_P12_PATH=/etc/geomdb/system-cert.p12
SYSTEM_CERT_PASSWORD=passphrase_sertifikat
```

Tanpa konfigurasi ini, TTE tetap berjalan secara manual oleh Walidata. Startup check akan menampilkan peringatan jika env var tidak diset.
