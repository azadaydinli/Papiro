# Papiro

**Türkçe** · [English](#english)

macOS için PDF görüntüleyici ve düzenleyici. Asıl işi, taranmış bir cildi ayrı belgelere bölmektir
(`Document_0001.pdf`, `Document_0002.pdf` …). Ayrıca:

- sayfaları döndürmek, eklemek, silmek, ayrı dosya olarak dışa aktarmak, dosyaları birleştirmek;
- taranmış sayfalarda kenarları (delik izleri, lekeler) ve gereksiz bölümleri gerçekten silmek;
- sayfaya metin yazmak ve PNG imza koymak;
- metinde arama.

Papiro Türkçe ve İngilizce kullanılabilir; dili macOS’un diline göre seçilir.

## İndirme

**[Papiro.dmg — son sürüm](https://github.com/azadaydinli/Papiro/releases/latest/download/Papiro.dmg)**

Gereksinim: macOS 26 veya daha yenisi; Apple Silicon ve Intel Mac’lerde çalışır.

## Kurulum

1. `Papiro.dmg` dosyasını açın ve **Papiro**’yu **Uygulamalar** klasörüne sürükleyin.
2. Papiro Apple tarafından imzalanmadığı için macOS ilk açılışta izin vermez:
   - Papiro’yu bir kez açmayı deneyin ve uyarıyı kapatın;
   - **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünün altında Papiro için **“Yine de Aç”** düğmesine basın;
   - açılan soruda yine **“Aç”**ı seçin.

   Bu yalnızca ilk kurulumda gerekir.

## Güncellemeler

Yeni bir sürüm çıktığında Papiro bunu kendisi bildirir (günde bir kez denetler; menüde
**Papiro → Güncellemeleri Denetle** de vardır). **“Güncelle”**ye basınca yeni sürüm indirilir, doğrulanır, kurulur ve
Papiro yeniden açılır. Denetim sırasında GitHub’a yalnızca son sürümün sorgusu gider; belgeleriniz ve onlarla ilgili hiçbir
bilgi gönderilmez.

---

## English

A PDF viewer and editor for macOS. Its main job is splitting a scanned volume into separate documents
(`Document_0001.pdf`, `Document_0002.pdf` …). It also:

- rotates, adds, deletes and exports pages, and merges files;
- really removes margins (punch holes, stains) and unwanted parts on scanned pages;
- writes text on pages and places PNG signatures;
- searches the text.

Papiro is available in Turkish and English; it follows the language of macOS.

### Download

**[Papiro.dmg — latest version](https://github.com/azadaydinli/Papiro/releases/latest/download/Papiro.dmg)**

Requires macOS 26 or later; runs on Apple Silicon and Intel Macs.

### Installing

1. Open `Papiro.dmg` and drag **Papiro** to the **Applications** folder.
2. Papiro is not signed by Apple, so macOS refuses to open it the first time:
   - try to open Papiro once and close the warning;
   - in **System Settings → Privacy & Security**, press **“Open Anyway”** for Papiro near the bottom;
   - choose **“Open”** in the question that follows.

   This is only needed for the first installation.

### Updates

When a new version is out, Papiro says so itself (it checks once a day; the menu also has
**Papiro → Check for Updates**). **“Update”** downloads the new version, checks it, installs it and opens Papiro again.
The check only asks GitHub for the latest release; nothing about your documents is sent.

---

## Building / Derleme

```
./build.sh                        # build.noindex/Papiro.app
./release.sh 1.0.3 notes.txt      # publish a new version on GitHub
```
