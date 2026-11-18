# Papiro

İstifadəçinin öz macOS PDF oxuyucusu və redaktoru. Əsas işi cinayət işinin skan edilmiş cildini sənədlərə
bölməkdir (Böl): `Document_0001.pdf`, `Document_0002.pdf` … Bu fayllar sonra EPİS-ə yüklənir.

**Böl tətbiqin əsas funksiyasıdır: onu pozan heç bir dəyişiklik qəbul edilmir.**

## Qaydalar
- AppKit + PDFKit, xarici asılılıq yoxdur, Xcode layihəsi yoxdur (`swiftc` ilə yığılır).
- macOS 26+, Apple-ın native Liquid Glass görünüşü: öz çəkilmiş görünüşlər yazılmır, sistemin elementlərindən istifadə olunur
  (`NSSplitViewController` + sidebar, `NSSplitViewItemAccessoryViewController`, `.glass` düymələr, `borderShape`, `tintProminence`).
- UI mətnləri Azərbaycan dilindədir.
- Hər dəyişiklikdən sonra `./build.sh` xətasız və xəbərdarlıqsız keçməli, tətbiq açılıb əllə yoxlanılmalıdır.
- Tapşırıqlar ardıcıl edilir, hər biri ayrıca git commit olur. İstifadəçi razılaşmadan dəyişiklik edilmir; tərəddüd olanda soruşulur.
- `UserDefaults` açarları (`splitFolder`, `splitPrefix`, `extractFolder`, `sidebarWidth`) dəyişdirilmir.
- Bundle id: `az.local.papiro`.
- `../epis-extension` qovluğu bu layihəyə aid deyil, ona toxunulmur (başqa sessiyada işlənir).

## İki Mac (iMac və MacBook)
- Bu qovluq Masaüstündədir və iCloud ilə hər iki Mac-də eynidir; `.git` də sinxronlaşır.
- **Eyni anda iki Mac-də dəyişiklik və ya commit etmə.** Bir Mac-də iş bitir, iCloud sinxronlaşır, sonra digərinə keçilir.
  İşə başlamazdan əvvəl `git status` və `git log` ilə vəziyyətə bax.
- Proqram iCloud-dan istifadə etmir; Böl işarələri hər Mac-də ayrıca, yerli saxlanır.

## Yığmaq və quraşdırmaq
```
./build.sh                                           # build.noindex/Papiro.app (iCloud-dan kənarda yığılır və imzalanır)
osascript -e 'tell application id "az.local.papiro" to quit'
ditto build.noindex/Papiro.app /Applications/Papiro.app
```
`build.sh` paketi müvəqqəti qovluqda yığır: iCloud Masaüstündəki paketə FinderInfo əlavə edir və `codesign` onu qəbul etmir.
Hər iki qovluğun adı `.noindex` ilə bitir: Spotlight onları indeksləmir, yoxsa hər yığma Proqramlar siyahısında
yeni bir "Papiro" qoyur və Masaüstündəki nüsxə də quraşdırılmışın yanında görünür.

## Buraxılış (GitHub)
- İctimai repo: `github.com/azadaydinli/Papiro`. İmzasız (ad-hoc) paylanır; ilk quraşdırmada "Yenə də aç" lazımdır (README).
- `./release.sh 1.0.1 qeydler.txt`: versiya + build nömrəsi, `Papiro.dmg` (insanlar üçün), `Papiro.zip` + `.sha256`
  (yeniləyici üçün), GitHub-da `v1.0.1` release. Endirmə linki: `releases/latest/download/Papiro.dmg`.
- Lokal git tarixçəsi GitHub-a **göndərilmir**: hər buraxılışda cari ağac GitHub-ın `main`-i üzərinə tək commit kimi
  gedir, müəllif GitHub noreply ünvanıdır. `git push` etmə; yalnız `release.sh`.
- Yeniləyici (`Updater`) `Bundle.main.bundleURL`-i əvəz edir; Masaüstündəki `build.noindex` nüsxəsi özü yoxlamır.

## Quruluş (`Sources/`)
| Fayl | Nə edir |
|---|---|
| `main.swift` | Proqramın başlanğıcı, menyular, "Faylları birləşdir" |
| `Updater.swift` | GitHub Releases-dən yeniləmə: gündə bir dəfə yoxlama, bildiriş, Papiro.zip + SHA-256 yoxlaması, əvəzetmə və yenidən açılış |
| `Welcome.swift` | Başlanğıc pəncərəsi (sənəd açıq olmayanda): "Fayl seç" və "Son baxılanlar" |
| `PDFDoc.swift` | `NSDocument`: PDF, səhifə əməliyyatları (`perform` → geri alınır), Böl işarələri (`groups`), diskdəki sıra (`diskIndex`) |
| `Marks.swift` | `MarkStore`: yarımçıq işarələmənin bərpası üçün işarələrin yerli müvəqqəti saxlanması |
| `DocWindowController.swift` | Pəncərə: üst bar, alətlər barı, sol panel, sağda imza paneli (inspector), rejimlər (`page`, `grid`, `split`, `margins`, `marginsApply`, `whiteout`, `text`), bütün əmrlər |
| `PageGrid.swift` | Səhifələr şəbəkəsi, Böl rejimində toplu vərəqlər (stack) və yığılma animasiyası, Shift+klik, "Tətbiq et" checkbox-ları |
| `SplitPanel.swift` | "Faylları yaz": qovluq, nömrələmə (qovluqdakı ən böyük nömrədən davam), fonda yazma, `.partial`, "Dayandır" |
| `Margins.swift` | "Kənarları təmizlə": məzmunun avtomatik tapılması (deşiklər və küncdəki nömrələr xaric), ağartma |
| `Redact.swift` | "Ağart": əl ilə çəkilən düzbucaqlıların ağardılması |
| `Annotate.swift` | "Mətn" (FreeText qutuları, `TextOverlay`) və "İmza" (sağ panel `SignaturePanel`, PNG-lər `~/Library/Application Support/Papiro/Signatures/`-də, `ImageAnnotation` Stamp); geri alınan `swapAnnotation` / `movedAnnotation` |
| `Scan.swift` | Skan səhifənin tanınması (səhifə boyda şəkil) və həqiqi silmə: səhifə skan həlletməsində yenidən şəkil kimi çəkilir |

"Kənarları təmizlə" və "Ağart" yalnız skan səhifələrdə işləyir və üstünü örtmür, silir: `Scan.redrawn` səhifəni skanın
həlletməsində bitmap-ə çəkir, ağ hissələri boyayır, JPEG (0.9) kimi yeni səhifəyə qoyur; köhnə şəkil faylda qalmır,
annotasiyalar köçürülür, gizli OCR mətni itir. Skan olmayan sənəddə bu düymələr deaktivdir.

Mətn və imza annotasiyadır: mətn saxlananda şrifti fayla yazılır; imzanı `ImageAnnotation.draw` çəkir və PDFKit bunu
görünüş (appearance) kimi saxlayır. `PDFPage.copy()` belə imzanı yalnız `ImageAnnotation.copy(with:)` sayəsində düzgün
kopyalayır; `makePDF` kopyanı əvvəl yeni sənədə qoyur, sonra `restoreSignatures` çağırır (kopyanı sənədə qoymadan
dəyişmək orijinalın sol panelini çökdürür).

Redaktə olunmuş səhifə (ağartma, kənar təmizləmə) yeni `PDFPage` olur; onun sahibi olan `PDFDocument` `keepAlive`-da saxlanmalıdır,
yoxsa səhifə boşalır. Köhnə səhifənin işarəsi və `diskIndex`-i `replaceInGroups` ilə yeniyə keçir.

## Böl işarələri
- Məqsəd: işarələmə yarımçıq qalsa (çökmə, elektrik kəsilməsi, səhvən çıxış), fayl yenidən açılanda işarələr yerində olsun.
- Yer: `~/Library/Application Support/Papiro/Marks/<fingerprint>.json` (yalnız bu Mac, iCloud yox). Hər dəyişiklikdən
  dərhal sonra yazılır; sənəd açılanda əsas thread-də oxunur (fayl kiçik və yerlidir).
- Müvəqqətidir: "Faylları yaz" hamısını yazıb bitirəndə (dayandırılmadan) həmin cildin faylı silinir
  (`PDFDoc.forgetStoredMarks`); 30 gündən çox dəyişməyən fayllar proqram açılanda silinir (`MarkStore.removeOld`).
- Fingerprint: `SHA256(ilk 1 MB + fayl ölçüsü + səhifə sayı)` — fayl adı dəyişsə də işarələr qalır.
- `groups` diskdəki faylın səhifə sırasına görədir; uğurlu saxlamadan sonra yeni fingerprint ilə yazılır, köhnə fayl silinir.
- İşarə əməliyyatları geri alınır, amma sənədi "dəyişdirilib" etmir (`PDFDoc.updateChangeCount`).

## Yoxlama
- Məntiq: `Sources/` (main.swift-dən başqa) + kiçik test `main.swift` ilə ayrıca `swiftc` proqramı yığılıb işə salınır
  (`PDFDoc`, `MarkStore`, `Margins` birbaşa çağırılır). Test faylları müvəqqəti qovluqda saxlanır və sonda silinir;
  testin yaratdığı işarə faylları da silinir.
- UI: proqram açılır və ekranda yoxlanılır. Ekran kilidli olanda: test `main.swift` `PDFDoc` + `DocWindowController` açır,
  rejimləri dəyişir və pəncərəni `cacheDisplay` ilə PNG-yə çəkir (animasiyalar orada işləmir).
- Böl-ün etibarlılığı üzrə texniki tapşırıq (T0–T4) icra olunub; sənəd qovluqdan silinib, git tarixçəsində qalır
  (`git show e6d802a:TEXNIKI-TAPSIRIQ.md`).
