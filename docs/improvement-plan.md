# Money Tracker: Rencana Pengembangan Lanjutan

Dokumen ini melanjutkan sistem money tracker yang sudah berjalan (Tahap 1). Isinya status saat ini, fitur yang dipilih untuk dikembangkan, rancangan teknis, urutan pengerjaan, dan keputusan yang masih terbuka.

---

## 1. Status Saat Ini

**Stack**
- n8n dipasang lewat npm di Windows (`n8n start`, `http://localhost:5678`), zona waktu workflow `Asia/Jakarta`.
- Ollama di Windows, model `qwen2.5:3b` (CPU only), dipanggil lewat `http://localhost:11434/api/chat`.
- Input lewat bot Telegram dengan **polling** (bukan webhook), karena n8n berjalan lokal tanpa alamat HTTPS publik.
- Penyimpanan utama: Google Sheets (spreadsheet "Money Tracker", tab `Transaksi`), terhubung lewat Service Account.

**Alur workflow sekarang**
```
Schedule Trigger (30 detik) / Manual Trigger
  -> Baca Offset
  -> Ambil Update        (getUpdates?limit=1&offset=...)
  -> Siapkan Pesan       (simpan offset baru, filter chat ID pemilik, abaikan perintah "/")
  -> Pesan
  -> Bangun Prompt
  -> Ollama              (JSON: kategori + keterangan)
  -> Validasi            (nominal rb/jt dengan aturan, tanggal dari $now, cek kategori)
  -> Valid?
       true  -> Google Sheets (Append Row) -> Balas
       false -> Balas ("Tidak paham, coba tulis ulang.")
```

**Kolom tab `Transaksi` sekarang**
`Tanggal | Jumlah | Kategori | Keterangan | Tipe | Pesan Asli`

**Prinsip desain yang dipertahankan**
1. AI hanya menentukan **kategori dan keterangan**.
2. Nominal diproses dengan aturan (`rb`, `ribu`, `k` x1.000; `jt`, `juta` x1.000.000; mendukung `1,5jt`), tanggal dari n8n.
3. Hasil AI selalu divalidasi sebelum disimpan.
4. Setiap pesan selalu dibalas, supaya salah baca langsung terlihat.
5. Kategori tetap: Makanan, Transport, Belanja, Tagihan, Hiburan, Lainnya, Pemasukan.

---

## 2. Keputusan Arah Pengembangan

- Pengguna hanya memakai **satu akun**, jadi pencatatan debit dan kredit penuh (berpasangan) **tidak** dipakai. Manfaat utamanya ada pada perpindahan antar akun, yang tidak terjadi di sini.
- Opsional untuk nanti: kolom `Debit` (uang masuk) dan `Kredit` (uang keluar) sebagai istilah ringan, dan kolom `Akun` kalau suatu hari punya akun kedua.
- **Fitur yang dipilih:**
  1. Perintah bot
  2. Anggaran per kategori
  3. Laporan bulanan

---

## 3. Prasyarat (Fase 0)

Selesaikan sebelum menambah fitur, karena semua fitur baru bertumpu pada polling yang sama.

1. **Masalah timeout di node `Ambil Update`** saat tidak ada pesan masuk (pesan yang ada tetap diproses normal).
   - Dugaan: (a) Telegram menahan koneksi seperti long poll, (b) Node.js mencoba IPv6 dulu padahal jaringan tidak mendukungnya, (c) timeout bawaan terlalu panjang.
   - Diagnosis: baca pesan error di tab Executions; tes `curl.exe` ke `getUpdates` dengan **offset yang sama dengan offset tersimpan** (bukan offset besar sembarangan) dan lihat apakah kembali cepat.
   - Pengaman: Options Timeout `15000`, Retry On Fail (3x, jeda 2 detik), On Error = Continue (regular output). Untuk IPv6: `$env:NODE_OPTIONS="--dns-result-order=ipv4first"` sebelum `n8n start`.
   - Alternatif: pakai `&timeout=20` di URL dengan Timeout node `30000`, dan interval Schedule tetap 30 detik supaya tidak ada dua permintaan bersamaan (Telegram membalas 409 untuk permintaan kedua).
2. **Ollama mati = pesan hilang.** Offset sudah maju sebelum Ollama dipanggil. Atur node Ollama ke Continue on Fail, lalu balas "Ollama tidak aktif, coba lagi nanti".
3. **Auto-start n8n** saat Windows menyala (`pm2` atau Task Scheduler), karena sekarang n8n hanya hidup selama jendela PowerShell terbuka.
4. **Dedup berbasis ID.** Simpan `update_id` Telegram sebagai ID transaksi (lihat bagian 4.1) supaya pesan yang sama tidak tercatat dua kali kalau offset gagal tersimpan.

---

## 4. Perubahan Skema Google Sheets

Tambahkan kolom di **akhir** tab `Transaksi` supaya mapping node yang ada tidak rusak:

`Tanggal | Jumlah | Kategori | Keterangan | Tipe | Pesan Asli | ID | Status`

- `ID`: `update_id` dari Telegram.
- `Status`: `Aktif` (bawaan) atau `Batal`. Semua laporan dan saldo hanya menghitung baris `Aktif`.
- Pastikan kolom `Tanggal` dibaca sebagai tanggal asli dan `Jumlah` sebagai angka (Cell Format: Let Google Sheets format).

Tab baru:

**`Pengaturan`**
| Kunci | Nilai |
|---|---|
| saldo_awal | (angka) |
| chat_id | (opsional, kalau tidak ditulis di kode) |

**`Anggaran`**
| Kategori | Batas Bulanan | Terpakai | Sisa | Persen |
|---|---|---|---|---|
| Makanan | 1500000 | rumus | rumus | rumus |

Contoh rumus `Terpakai` (sesuaikan huruf kolom dengan layout tab `Transaksi`: A Tanggal, B Jumlah, C Kategori, E Tipe, H Status):
```
=SUMIFS(Transaksi!B:B, Transaksi!C:C, A2, Transaksi!E:E, "Pengeluaran", Transaksi!H:H, "Aktif", Transaksi!A:A, ">="&DATE(YEAR(TODAY()),MONTH(TODAY()),1))
```
`Sisa = B2 - C2` dan `Persen = C2 / B2`. Dengan rumus di Sheets, n8n cukup **membaca** tab `Anggaran`, tanpa menghitung sendiri.

---

## 5. Fitur 1: Perintah Bot

**Perubahan di `Siapkan Pesan`**: pesan yang diawali `/` tidak lagi dibuang, tetapi diberi penanda `jenis: "perintah"` beserta nama perintah dan argumennya (buang akhiran `@namabot` kalau ada). Pesan biasa diberi `jenis: "transaksi"`. Setelah itu tambahkan node **Switch** untuk mengarahkan alur.

| Perintah | Fungsi |
|---|---|
| `/bantuan` | Daftar perintah dan contoh penulisan transaksi |
| `/saldo` | Saldo sekarang = saldo awal + total Pemasukan - total Pengeluaran (baris `Aktif`) |
| `/hariini` (opsional) | Ringkasan pengeluaran hari ini |
| `/anggaran` | Tampilkan sisa anggaran per kategori bulan ini |
| `/laporan` | Laporan bulan berjalan (format sama dengan laporan bulanan) |
| `/batal` | Batalkan transaksi **terakhir** |

**Cara kerja `/batal`:** jangan hapus baris. Cari baris `Aktif` terakhir milik pemilik, ubah `Status` menjadi `Batal`, balas "Dibatalkan: ...". Jejak tetap ada dan semua laporan otomatis ikut benar.

---

## 6. Fitur 2: Anggaran per Kategori

- Batas bulanan disimpan di tab `Anggaran` (diisi langsung di Sheets dulu; pengaturan lewat bot bisa menyusul).
- Setelah transaksi **Pengeluaran** berhasil disimpan, workflow membaca baris kategori itu di tab `Anggaran` dan menambahkan peringatan ke balasan:
  - Persen >= 80%: `Perhatian: anggaran Makanan terpakai 85% (sisa Rp225.000).`
  - Persen >= 100%: `Anggaran Makanan terlampaui Rp40.000.`
- Kalau kategori tidak punya batas, balasan tidak ditambah apa pun.
- Karena penghitungan memakai `SUMIFS` di Sheets, ada jeda sangat singkat setelah baris ditulis. Beri node baca `Anggaran` sedikit penundaan (Wait 1-2 detik) atau hitung ulang tambahan transaksi ini di Code node.

---

## 7. Fitur 3: Laporan Bulanan

**Pemicu**
- Otomatis: Schedule Trigger tanggal 1 tiap bulan, jam 08:00 (zona Asia/Jakarta), melaporkan **bulan sebelumnya**.
- Manual: perintah `/laporan` untuk bulan berjalan.

**Isi laporan** (dihitung dengan Code node, bukan AI)
1. Total pemasukan, total pengeluaran, selisih.
2. Pengeluaran per kategori: nominal, persen dari total, dan perbandingan dengan anggaran.
3. Tiga pengeluaran terbesar (keterangan dan nominal).
4. Saldo akhir bulan.

**Contoh format balasan**
```
Laporan Oktober 2026
Pemasukan : Rp3.000.000
Pengeluaran: Rp1.850.000
Selisih   : +Rp1.150.000

Per kategori:
Makanan   Rp900.000 (49%) / anggaran Rp1.500.000
Transport Rp400.000 (22%)
...

Terbesar: sepatu Rp450.000, listrik Rp350.000, ...
Saldo akhir: Rp2.350.000
```

**Opsional nanti:** simpan juga ke tab `Laporan` di Sheets atau ke catatan Obsidian (lewat plugin Local REST API). Satu kalimat ringkasan oleh AI bisa ditambahkan, tetapi dengan model 3B hasilnya perlu diuji dulu.

---

## 8. Urutan Pengerjaan

| Fase | Isi |
|---|---|
| 0 | Prasyarat bagian 3 (timeout, Ollama mati, auto-start, dedup ID) |
| 1 | Skema Sheets (ID, Status, tab Pengaturan dan Anggaran), routing perintah dengan Switch, `/bantuan` dan `/saldo` |
| 2 | `/batal`, anggaran per kategori dengan peringatan, `/anggaran` |
| 3 | Laporan bulanan otomatis dan `/laporan` |
| 4 (opsional) | Kolom Debit/Kredit ringan, akun kedua, utang dan piutang, ringkasan ke Obsidian |

---

## 9. Keputusan yang Masih Terbuka

1. Batas anggaran diatur langsung di Sheets, atau lewat perintah bot (`/anggaran Makanan 1,5jt`)? Usulan: di Sheets dulu.
2. Apakah anggaran diisi juga untuk Tagihan dan Hiburan, atau hanya kategori pengeluaran utama?
3. Ambang peringatan: 80% dan 100%, atau angka lain?
4. Jam kirim laporan bulanan: usulan 08:00.
5. `/batal` hanya transaksi terakhir, atau bisa memilih transaksi tertentu?
6. Saldo awal: berapa, dan tanggal mulai pencatatan?

---

## 10. Catatan Teknis

- Static data n8n (tempat offset disimpan) hanya tersimpan saat workflow **dipublikasikan dan dipicu otomatis**; uji manual tidak menyimpannya.
- Pengaturan "Save successful production executions" sebaiknya tetap `Do not save` supaya riwayat tidak membengkak oleh polling.
- Token bot Telegram dan file JSON Service Account bersifat rahasia: jangan ikut dalam file ekspor workflow yang dibagikan.
- Uji tiap fitur baru dengan kasus: pesan biasa, `halo` (harus ditolak), dua pesan beruntun, perintah dengan argumen salah, dan pesan dari chat lain (harus diabaikan).

---

*Cara memakai file ini: unggah atau tempel isinya di awal chat baru, lalu tulis misalnya: "Lanjutkan dari rencana ini, kita mulai Fase 1" atau "Masalah timeout Ambil Update-ku masih ada, bantu selesaikan dulu."*
