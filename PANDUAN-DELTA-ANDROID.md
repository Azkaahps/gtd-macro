# PANDUAN — Roblox GTD Macro Recorder di Android (Delta)

Panduan khusus HP Android + Delta Executor. Semua nama menu Delta bisa beda tipis antar versi — gue tulis
berdasarkan **fungsi**-nya, jadi walau labelnya beda lu tetap ngerti maksudnya.

> **Intinya satu baris.** Setelah setup awal, tiap mau pakai lu cuma paste satu baris ini di Delta dan tekan
> Execute. Gak ada file yang perlu lu pindahin, gak ada 106 KB yang perlu lu paste.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main/Loader.lua"))()
```

---

## 0. 60 detik quickstart (buat yang udah pernah)

1. Buka Delta → **Attach/Inject** → tunggu notif "attached".
2. Buka **Garden Tower Defense**, tunggu masuk lobby.
3. Paste baris di atas → **Execute**.
4. Muncul toast `loaded · file api ok · touch sim ok` + panel kecil kiri atas.
5. Masuk ke map/mode yang mau lu farm → **SETUP → RUN DISCOVERY** → **PIN ANCHOR**.
6. Ronde **JANGAN** dimulai dulu → tekan **RECORD** → main normal 1 ronde (place + upgrade unit) →
   **STOP & SAVE** → kasih nama.
7. Ronde baru, setup sama → **MACROS → GO**. Panel sembunyi sendiri, tinggal pill **STOP** di kiri atas.

Sisanya di bawah ini: kenapa, apa yang bisa bikin gagal di HP, dan apa yang harus lu kirim kalau meleset.

---

## 1. Persiapan HP (sekali saja)

### 1.1 Delta Executor
| Hal | Keterangan |
|---|---|
Sumber | situs resmi Delta (APK). Jangan dari link random di YouTube/Discord — varian bajakan sering ada tambahan iklan/malware. |
Android | 8.0 atau lebih baru; RAM 3 GB disarankan biar Roblox + Delta gak saling bunuh |
Izinkan install | Pengaturan → aplikasi → **Install unknown apps** untuk browser/file manager lu |
Roblox | harus sudah terpasang dari Play Store (versi normal, bukan versi mod) |
Attach | Delta punya tombol **Attach / Inject / Launch**. Tekan itu, tunggu sampai statusnya jelas "attached" — kalau gagal, tutup Roblox, tutup Delta, ulangi. |

### 1.2 Baterai & RAM (ini penyebab nomor satu macro putus di tengah jalan)
Android produksi HP (Xiaomi, Oppo, Vivo, Realme, Huawei, Samsung) agresif membunuh proses background:

1. Pengaturan → aplikasi → **Delta** → **Baterai** → pilih **Tidak dibatasi / No restrictions**.
2. Aktifkan **Autostart** (kalau ada) untuk Delta.
3. Kunci Delta di recent-apps (ikon gembok) biar gak ke-swipe keluar.
4. **Matikan screen timeout atau set lama** (mis. 30 menit) dan **jangan lock layar** — lock layar = game
   pause = macro nganggur. Paling aman: charge sambil jalan.
5. **Roblox → Pengaturan → Graphics** turunin ke manual level 1–2. Frame drop bikin aksi telat dan status
   bar lu bakal naik di kolom `late`.

### 1.3 Gangguan dari luar (ini bikin tap nyasar)
Selama **record** dan **playback**:
- Aktifkan **mode Jangan Ganggu / Do Not Disturb**, matikan popup notifikasi (WA, Telegram, dll).
- Matikan **floating bubble / Assistive Touch / tombol mengapung aplikasi lain** — kalau ada bulatan nyempil
  di tengah layar, game bisa nerima tap itu sebagai "tap player".
- Jangan pakai split-screen / floating window; layout layar berubah = koordinat berubah.
- Kunci **orientation** (landscape) dan jangan diputar-putar selama rekam/replay.
- Jangan multitouch (dua jari atau lebih) waktu rekam — Android ngirimin beberapa touch id sekaligus dan itu
  kecatet sebagai step tambahan.

---

## 2. Load script-nya di Delta

1. Buka Delta → tab script (biasanya **Execute** / **Scripts** / **Works**).
2. **Copy** baris loadstring di paling atas panduan ini (tahan → Copy).
3. Tahan di kotak script Delta → **Paste** → **Execute**.
4. Performa pertama kali: Delta nge-`HttpGet` ~104 KB dari GitHub, jadi butuh 1–3 detik. Setelah itu
   `Main.lua` ke-cache di folder `ANON_GTD/` sehingga load berikutnya instan dan tetap jalan walau GitHub
   sedang ngadat.
5. **Simpan sebagai script** di daftar Delta (fitur "Save"/"Add script", nama persisnya beda-beda per versi)
   dengan nama mis. `GTD ANON`. Habis ini lu gak perlu paste lagi, cuma tap script itu → Execute.

### Kalau gagal execute
| Pesan / gejala | Artinya | Aksi |
|---|---|---|
`attempt to call a nil value (global 'HttpGet')` | executor lu gak punya `game:HttpGet` | pakai executor lain; tanpa HttpGet, loadstring dari web mustahil |
`could not fetch Main.lua` | URL salah, repo di-private, atau internet mati | cek repo masih public; atau langsung paste isi `Main.lua` ke kotak script |
`compile error: ...` | payload ke-truncate / ketahan halaman proxy WiFi | jalankan ulang (loader bakal pakai mirror/cache); kalau wifi kantor/sekolah suka nge-blokir, pakai data seluler |
Gak ada toast & panel | script gak kejalan sama sekali | inject ulang; cek Delta diizinkan "no restrictions" |

---

## 3. Kenali UI-nya (dari layar HP)

Panel muncul di kiri atas, ukuran 400 × 366 px. Di HP layar kecil:
- **Geser panel**: tahan **header**-nya (bar judul), geser pakai jari.
- **Sembunyikan panel**: tombol **—** di kanan atas header. Munculkan lagi: tap **—** lagi.
- **Tutup total**: tombol **x** (kanan atas). Munculin lagi: execute ulang script.
- **Saat playback panel sembunyi sendiri** dan yang tersisa cuma pill merah **STOP** di kiri atas — ini
  sengaja, biar tap hasil replay gak ketahan UI kita sendiri. Pill-nya kecil; taruh Delta-nya di sisi lain.

Tabnya cuma empat: **RECORD · MACROS · SETUP · CONFIG**. Status bar tipis di paling bawah panel nunjukin apa
yang sedang terjadi (`idle`, `recording`, atau `PLAY ▶ step n/N …`).

---

## 4. Setup awal di game (SEKALI, ±2 menit)

Semua ini **harus di dalam map/match**, bukan di lobby — mode, difficulty, map, dan speed cuma ada saat lu
sudah di dalam run.

### 4.1 SETUP → RUN DISCOVERY
Yang gue cari di report-nya:

| Baris | Bagus | Kalau salah |
|---|---|---|
`mode` | `Classic` / `Survival` / `Dojo` | override: `mode=Dojo` |
`difficulty` | `Easy`/`Normal`/`Hard`/`Impossible` | override: `difficulty=Impossible` |
`map` | nama map atau `map#123456789` | override: `map=<nama di game>` |
`speed` | `1` / `2` / `3` | override: `speed=3` |
`waves` | `3 / 25` (angka asli) | kalau `nil / nil` → 4.2b |
`countdown` | angka dekat wave | gak fatal |
`loadout` | unit equip lu / `none detected` | gak fatal, cuma buat warning |
`wave label` | path panjang | 4.2 |
`touch sim` | `available` | kalau `unavailable`, klik lewat mouse — biasanya tetap kena |

### 4.2a Kalau `waves` kebaca → tekan **PIN ANCHOR**
Discovery lagi, pastikan path-nya muncul di baris `ANCHORS > wave label`. Selesai — anchor kekunci permanen.

### 4.2b Kalau `waves` = `nil / nil`
Tekan **MARK WAVE NOW** tepat saat ronde baru mulai. Sementara macro lu bakal jalan pakai patokan waktu
absolut (kurang presisi). Kirim report-nya ke gue, gue pin manual path yang benar.

### 4.3 Override manual (kalau auto-detect salah)
Ketok kotak paling bawah tab SETUP, tulis: `mode=Impossible, speed=3, map=Dojo` → **apply** → discovery lagi.
Override disimpan di `ANON_GTD/profile.json` dan selalu menang atas deteksi otomatis.

### 4.4 CALIBRATE TAP — hanya kalau tap meleset
Kalau saat replay tap-nya meleset beberapa pixel (kena tapi salah tombol/tile), tekan **CALIBRATE TAP** →
muncul tanda **+** kuning → tap **+** itu sekali → offset tersimpan. Kalau tap-nya udah pas, **jangan**
kalibrasi.

---

## 5. Rekam macro (1 ronde)

1. Pastikan lagi: HP landscape, notifikasi mati, Delta "no restrictions", layar gak akan ke-lock.
2. Mulai ronde (wave 1) dulu, baru tekan **RECORD** — atau tekan RECORD tepat sebelum wave mulai. Header REC
   bakal nunjukin stempel konteks (`Classic · Impossible · Dojo · x3 · waves 3/25`) dan hitungan step.
3. Lakukan apa yang lu mau diulang, **wajar**, gak usah buru-buru:
   - place unit (tap ground),
   - upgrade unit (tap unit → tap tombol upgrade),
   - kalau perlu drag/gulir kamera.
   Semua ini kebaca: tap, drag, dan tombol keyboard kalau lu pakai gamepad/keyboard eksternal.
4. Tekan **STOP & SAVE**. Isi nama (opsional, mis. `impossible-dojo`), atau biarin auto.
5. Cek di tab **MACROS**: barisnya harus nunjukin stempel lengkap dan `steps` > 5.

**Catatan penting:** kalau lu tap UI panel kita sendiri, tap itu **tidak** ikut kecatet (sengaja). Jadi
nyentuh panel di tengah rekaman aman — tapi jangan dipakai buat hal aneh, tetap aja lakuin sesuai gameplay.

## 6. Putar ulang macro

1. Balik ke setup yang **sama** (mode + difficulty + map + speed sama). Ini bukan formalitas: unit dan harga
   seed beda per mode, dan tempat valid-nya beda per map.
2. Kalau counter wave udah lewat `wave` awal macro, script **nahan** sampai ronde restart (itu sengaja,
   bukan hang). Kalau lu gak mau nunggu: **MACROS → GO** aja, lalu biarin, dia bakal nunggu sendiri.
3. Kalau stempel-nya beda, muncul panel **PLAY ANYWAY / CANCEL** berisi daftar bedanya. Kalau bedanya gak
   sengaja → **CANCEL**, perbaiki dulu.
4. Selama jalan, baca status bar:
   `PLAY ▶ step n/N wave W late L missed M ok V fail F`
   - `ok` naik = unit beneran ke-pasang (terverifikasi).
   - `fail` naik = placement gagal; cek seed / slot unit.
   - `late` naik = HP lu ngelag atau lock layar; turunin grafis.
   - `missed` naik = kelewat ronde (script ngejar).
5. Mau berhenti: pill **STOP** (atau dari console: `getgenv().ANON_GTD.player.stop()`).
6. **Loops** (di tab MACROS): 1 / 5 / 25 / ∞. Buat malam-malam pakai ∞ tapi tetap awasin 1–2 putaran
   pertama.

## 7. History & pin

Di tab **MACROS** setiap baris nunjukin stempelnya — itu yang bikin lu bisa bedain macro
(`Impossible · Classic · Dojo · x3 · 25 waves · 143 steps · 2026-11-12 18:31`).

| Tombol | Fungsi |
|---|---|
`GO` | putar |
`PIN` | tandai penting → otomatis naik ke urutan paling atas |
`NM` | ganti nama |
`EXP` | export jadi string base64 (otomatis ke clipboard kalau executor lu punya `setclipboard`; Delta punya) — buat backup / pindah HP |
`DEL` | hapus (ada konfirmasi) |

Kotak **filter** buat nyari berdasarkan nama/mode/map, dan tombol **pinned only** buat nyembunyiin sisanya.
Import hasil export: tab **CONFIG → import macro (base64)** → paste → Enter.

## 8. Di mana file-nya disimpan (Android)

Semua ada di folder kerja Delta (lokasi persisnya beda per versi Delta, tapi polanya sama):

```
ANON_GTD/
  index.json       daftar macro buat tabel history
  profile.json     pin: label wave, container unit, offset tap, override
  macros/<id>.json isi rekaman
  Main.lua         cache script (dibuat oleh Loader)
```

Cara lihat/pindahin: pakai file manager bawaan Delta (kalau ada), atau dari console:
```lua
print(table.concat(listfiles("ANON_GTD/macros"), "\n"))
print(readfile("ANON_GTD/profile.json"))
```
Kalau executor lu gak punya `writefile`, kamu bakal lihat toast `no file api (session only)` — macro tetap
jalan tapi hilang begitu keluar game. Saran: export (base64) macro penting sebelum keluar.

## 9. Hapus / update / bersihin

| Aksi | Cara |
|---|---|
Hapus satu macro | MACROS → `DEL` |
Lihat jumlah macro | SETUP → tombol **DROP MACROS** (nampilin jumlah + folder) |
Update script ke versi baru | **execute ulang baris loadstring-nya** — Loader ambil versi terbaru, gak perlu paste Main.lua |
Paksa gak pakai cache | tambahkan `?v=` (udah otomatis dilakukan loader) atau hapus `ANON_GTD/Main.lua` |
Bersihin total | keluar game → hapus folder `ANON_GTD` dari file manager Delta |

## 10. Kalau ada yang aneh

| Gejala di HP | Penyebab paling sering | Aksi |
|---|---|---|
Panel gak muncul | script gagal jalan, atau UI lama masih nyangkut | execute ulang; kalau masih, rejoin server |
Panel ketutup notch/status bar | posisi awal panel kegeser | geser panel dari header-nya |
Tap replay gak ngefek di tombol game | game cuma nanggepin event `Activated` | CONFIG → `click method: ui` → GO lagi |
Unit mendarat di tile sebelah | kamera muter/map beda | pastikan kamera sama posisinya; coba CONFIG → `follow world point: OFF` |
Semua aksi nyembur sekaligus | counter wave gak kebaca → mode waktu absolut | SETUP → PIN ANCHOR / MARK WAVE NOW |
Gak ada aksi sama sekali | counter nunjukin ronde beda dari start macro | lihat `wave W` di status bar |
`late` naik terus | HP ngelag / layar ke-lock / ada app lain makan RAM | grafis ke 1–2, DND on, charge sambil jalan |
Proses Delta mati sendiri di tengah | battery manager OEM | izin "no restrictions" + autostart |
Layar HP mati → macro berhenti | screen timeout | set timeout lama / matikan lock |
Notifikasi nyempil → tap nyasar | popup masuk | mode DND |

## 11. Yang gue butuh kalau ada masalah

1. **SETUP → COPY REPORT** (kalau `setclipboard` gak jalan, report otomatis ke-print di console Delta) —
   atau via console: `print(getgenv().ANON_GTD.probe.report.text)`
2. Nama macro yang lu tes + satu kalimat: "yang beda apa" (mis. "unitnya mendarat 1 tile ke kiri").
3. Screenshot status bar pas `PLAY ▶ …` kalau ada `fail`/`late` naik.

Dengan itu gue pin label wave & container unit asli ke config, push revisi, dan lu cuma execute ulang baris
loadstring tadi — gak ada paste-paste lagi.

## 12. Etika & risiko (jujur, singkat)

Ini alat macro/replay — dia **menirukan input lu**, bukan nge-*fire* remote game (kecuali dengar pasif buat
anchor). Risiko deteksi lebih rendah dibanding script farm yang nembak remote, tapi **bukan nol**: main
nonstop 24 jam dengan delay identik = pola bot. Mitigasi yang udah ada di tab **CONFIG**: jitter posisi
(0–4 px) dan jitter waktu (0–50 ms) — naikin sedikit kalau lu bakal jalan lama.

Aturan praktis: **pakai akun alt** buat nge-tes dan buat farming panjang, main di difficulty gampang buat uji
coba pertama, dan tetap main manual sesekali di akun utama. Ban di Roblox sifatnya per-game (`BanAsync`), dan
itu keputusan developer game — bukan sesuatu yang bisa gue jamin aman 100%.
