# Incident Response Runbook — geoMDB-hub

Dokumen ini berisi prosedur untuk menangani insiden umum pada sistem geoMDB-hub.
Update setelah setiap insiden dengan lessons learned.

---

## Klasifikasi Insiden

| Severity | Kriteria | Waktu Respons |
|----------|----------|---------------|
| P1 — Kritis | Sistem tidak bisa diakses, data bocor, autentikasi bypass | < 30 menit |
| P2 — Tinggi | Fitur utama tidak berfungsi, performa sangat lambat | < 2 jam |
| P3 — Sedang | Fitur minor gagal, error sporadis | < 1 hari kerja |
| P4 — Rendah | Peringatan, optimasi, pertanyaan | < 3 hari kerja |

---

## 1. Sistem Tidak Bisa Diakses (P1)

```bash
# 1. Cek status container
docker compose ps

# 2. Cek log error terbaru
docker compose logs --tail=50 app
docker compose logs --tail=50 nginx

# 3. Cek health endpoint
curl -I http://localhost:3000/api/ping

# 4. Restart jika perlu
docker compose restart app

# 5. Rebuild jika image korup
docker compose up -d --build app
```

**Eskalasi:** Jika container terus crash → cek `docker compose logs app` untuk OOM atau error startup.

---

## 2. Database Tidak Bisa Diakses (P1)

```bash
# Cek status postgres
docker compose ps postgres
docker compose logs --tail=30 postgres

# Test koneksi manual
docker exec geomdb_postgres pg_isready -U geomdb -d geomdb_hub

# Cek disk penuh (penyebab umum)
df -h
docker system df

# Restart postgres (kehilangan koneksi aktif, aplikasi akan reconnect)
docker compose restart postgres

# Jika data korup — restore dari backup
gunzip -c /backup/geomdb_hub_LATEST.sql.gz | \
  docker exec -i geomdb_postgres psql -U geomdb geomdb_hub
```

---

## 3. Redis Tidak Bisa Diakses (P2)

Dampak: rate limiting nonaktif (fail-open), session blacklist tidak berfungsi.

```bash
docker compose ps redis
docker compose logs --tail=30 redis
docker compose restart redis
```

**Catatan:** Setelah Redis restart, semua JWT blacklist hilang. User yang baru logout bisa
re-login dengan token lama hingga token expired (maks 8 jam). Acceptable untuk P2.

---

## 4. Login Tidak Bisa / Autentikasi Gagal (P1)

```bash
# Cek log auth
docker compose logs app | grep -i "auth\|login\|otp\|session"

# Cek apakah Redis aktif (session blacklist)
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD ping

# Cek apakah captcha Redis berfungsi
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD keys "pow:*" | wc -l

# Reset rate limit jika admin terkunci
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD del "login:rate:IP_ADDRESS"
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD del "login:email:EMAIL_HASH"
```

---

## 5. Email/Notifikasi Tidak Terkirim (P2)

```bash
# Cek status ext-serv
docker compose ps ext-serv
docker compose logs --tail=50 ext-serv

# Test koneksi SMTP via UI admin
curl -X POST https://yourdomain/api/admin/organisasi/email/test \
  -H "Cookie: session=..." 

# Restart ext-serv
docker compose restart ext-serv
```

---

## 6. Auto-Sign Gagal / TTE Tidak Jalan (P2)

```bash
# Cek log auto-sign worker
docker compose logs app | grep -i "auto-sign\|bullmq\|queue"

# Cek antrian BullMQ di Redis
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD keys "bull:auto-sign:*" | head -20

# Lihat job gagal
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD \
  lrange "bull:auto-sign:failed" 0 10

# Cek apakah cert sistem ada
ls -la $SYSTEM_CERT_P12_PATH

# Force retry: hapus job failed dari queue (akan auto-retry next restart)
# ATAU gunakan TTE manual via UI Walidata
```

---

## 7. Storage MinIO Penuh / File Hilang (P2)

```bash
# Cek penggunaan disk
docker exec geomdb_minio df -h /data

# Cek bucket
docker exec geomdb_minio mc du local/geomdb-hub --depth 1

# Hapus file lama jika darurat (HATI-HATI — konfirmasi dulu dengan PIC)
# docker exec geomdb_minio mc rm local/geomdb-hub/qcqe/OLD_ID/ --recursive

# Cek file yang hilang (qcqeId ada di DB tapi file tidak ada di MinIO)
docker exec geomdb_postgres psql -U geomdb geomdb_hub \
  -c "SELECT id, signedPdfPath FROM \"QCQERecord\" WHERE signedPdfPath IS NOT NULL LIMIT 10;"
```

---

## 8. Kerentanan Keamanan Ditemukan (P1)

1. **Isolasi:** Nonaktifkan endpoint yang rentan jika memungkinkan
2. **Assess:** Tentukan data apa yang terekspos, siapa yang bisa eksploitasi
3. **Patch:** Deploy fix secepat mungkin
4. **Notifikasi:** Beritahu pengguna jika data mereka terekspos
5. **Dokumentasi:** Catat di log insiden

```bash
# Blok IP penyerang di Nginx sementara
docker exec geomdb_nginx nginx -s reload

# Paksa logout semua user (hapus semua JTI)
docker exec geomdb_redis redis-cli -a $REDIS_PASSWORD keys "user:jti:*" | \
  xargs docker exec -i geomdb_redis redis-cli -a $REDIS_PASSWORD del
```

---

## 9. Data Breach / Dugaan Akses Tidak Sah (P1)

1. **SEGERA:** Nonaktifkan semua akun yang diduga terkompromi
2. Backup log akses sebelum ada yang menghapus:
   ```bash
   docker compose logs --no-log-prefix app > /tmp/incident_$(date +%Y%m%d_%H%M%S).log
   ```
3. Preserve evidence sebelum restart/cleanup
4. Hubungi kontak keamanan: `geometadataindonesia@gmail.com`
5. Laporkan ke BSSN/CSIRT jika melibatkan data pemerintah

---

## Checklist Pasca-Insiden

- [ ] Root cause teridentifikasi
- [ ] Fix diterapkan dan diverifikasi
- [ ] Log insiden ditulis (tanggal, severity, dampak, timeline, fix)
- [ ] Backup terverifikasi masih valid
- [ ] Pengguna dinotifikasi jika diperlukan
- [ ] Runbook ini diupdate dengan lessons learned

---

## Kontak Darurat

| Peran | Kontak |
|-------|--------|
| Tim IT | geometadataindonesia@gmail.com |
| Keamanan BSSN/CSIRT | csirt@bssn.go.id |
| Vendor Hosting | (isi sesuai instansi) |
