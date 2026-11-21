# Papiro

İstifadəçinin öz macOS PDF oxuyucusu və redaktoru. Əsas işi cinayət işinin skan edilmiş cildini sənədlərə
bölməkdir (Böl): `Document_0001.pdf`, `Document_0002.pdf` … Bu fayllar sonra EPİS-ə yüklənir.

**Böl tətbiqin əsas funksiyasıdır: onu pozan heç bir dəyişiklik qəbul edilmir.**

## Qaydalar
- AppKit + PDFKit, xarici asılılıq yoxdur, Xcode layihəsi yoxdur (`swiftc` ilə yığılır).
- macOS 26+, Apple-ın native Liquid Glass görünüşü: öz çəkilmiş görünüşlər yazılmır, sistemin elementlərindən istifadə olunur
  (`NSSplitViewController` + sidebar, `NSSplitViewItemAccessoryViewController`, `.glass` düymələr, `borderShape`, `tintProminence`).
- UI mətnləri iki dildədir: ingiliscə və türkcə (Azərbaycan dili yoxdur). Kodda mətn ingiliscə yazılır və `L("…")` ilə
  çağırılır (`Localize.swift`; dəyərli mətn: `L("Files created: %d", n)`), türkcəsi `Resources/tr.lproj/Localizable.strings`-də.
  Yeni mətn əlavə edəndə türkcəsi də o fayla yazılır. Dili macOS seçir (istifadəçinin dil sırasında türkcə ingiliscədən
  əvvəldirsə türkcə); macOS-un öz menyu bəndləri (Çoğalt, Geri Dön…) də həmin dildə olur, onlara toxunulmur.
- Hər dəyişiklikdən sonra `./build.sh` xətasız və xəbərdarlıqsız keçməli, tətbiq açılıb əllə yoxlanılmalıdır.
- Tapşırıqlar ardıcıl edilir, hər biri ayrıca git commit olur. İstifadəçi razılaşmadan dəyişiklik edilmir; tərəddüd olanda soruşulur.
- `UserDefaults` açarları (`splitFolder`, `splitPrefix`, `extractFolder`, `sidebarWidth`) dəyişdirilmir.
- Kursorlar Önizleme kimidir: PDFKit skan səhifədə (şəkil) hər yerdə barmaq göstərir; `PageView.setCursorFor` / `fixCursor` onu düzəldir (mətndə I-beam, keçiddə barmaq, başqa yerdə ox); alət açıqdırsa kursoru alət verir (`cursor(at:)`: kənarlarda `NSCursor.frameResize`, içəridə əl; Ağart-da crosshair; Mətn-də I-beam).
- Üst bar Önizleme kimidir (sağdan): axtarış (`NSSearchToolbarItem`), Çap et və Paylaş (iki adi element yan-yana: sistem onları ayırıcısız bir kapsula birləşdirir),
  Səhifə / Şəbəkə, Kiçilt / faiz (klik — seçimlər) / Böyüt, Geri al / İrəli al, Sola / Sağa döndər, Alətlər (alətlər barını
  göstərir/gizlədir, `toolsShown`). Döndər, Geri al / İrəli al, Çap et / Paylaş ayrı-ayrı adi düymələrdir: sistem yan-yana olanları ayırıcısız bir kapsula birləşdirir, aralarındakı `.space` kapsulları ayırır (ölçülər Önizleme kimi: tək 29, cüt ~65–68 nöqtə; üst barda kapsul enini AppKit təyin edir);
  Səhifə / Şəbəkə və miqyas şəkilli `NSToolbarItemGroup` (seqmentli, ayırıcı xətlərlə); qrup hissələrinin aktivliyini AppKit yoxlamır, `updateToolbarStates` edir. İpuclarında yalnız düymənin adı olur.
- "Sayfayı Sığdır" səhifəni üstdə və altda 12 nöqtəlik boşluqla (iki səhifə arası məsafənin yarısı) ortalayır; səhifəyə keçid (sol panel, Əvvəlki / Növbəti, şəbəkədən) bu miqyasda da ortalayır (`showPage`). Birinci və sonuncu səhifə üçün scroll view-un yuxarısında və aşağısında səhifə arası boşluq qədər yer var (`gapInset`, `contentInsets`), yoxsa AppKit görünüşü sənəd kənarına çəkirdi.
- Səhifə dəyişiklikləri və onların geri alınması animasiyasızdır (`PDFDoc.perform` / `registerRestore` → `withoutAnimation`), yoxsa PDFKit köhnə səhifəni yeninin üstündə soldururdu.
- Döndərmədə miqyas dəyişmir: döndərilən səhifə (görünüşün ortasındakı, `focusBeforeChange`) eyni miqyasda göstərilir; səhifə dəyişiklikləri animasiyasız yerləşir (`docChanged`, `CATransaction.setDisableActions`). Ortalama heç vaxt sənəd sərhədindən kənara çıxmır (`centre`, `constrainBoundsRect`), yoxsa AppKit sonra görünüşü birdən geri çəkir.
- Miqyas balonunun orta hissəsi sabit enlidir (`fixZoomWidth`: "1000%" / "420 px" sığır), üst bar uzanıb-qısalmır.
  Panellər (alətlər barı, sol panel, imza paneli) sürüşərkən səhifə hər kadrda sığdırılır (yumşaq böyüyüb-kiçilir), balondakı faiz isə yalnız animasiya bitəndə bir dəfə yenilənir (`animatePanels`).
- Başlıq altında yazı yoxdur: səhifə nömrəsi ("3 / 120") və şəbəkədə seçim / işarələr sağ aşağı küncdəki şüşə balondadır (`PageBubble`).
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
`build.sh` universal yığır: proqram `arm64` və `x86_64` üçün ayrıca yığılıb `lipo` ilə bir fayla birləşdirilir, ona görə Apple Silicon və Intel Mac-də (macOS 26+) işləyir; hansı Mac-də yığılmasından asılı deyil.
`build.sh` paketi müvəqqəti qovluqda yığır: iCloud Masaüstündəki paketə FinderInfo əlavə edir və `codesign` onu qəbul etmir.
Hər iki qovluğun adı `.noindex` ilə bitir: Spotlight onları indeksləmir, yoxsa hər yığma Proqramlar siyahısında
yeni bir "Papiro" qoyur və Masaüstündəki nüsxə də quraşdırılmışın yanında görünür.

## Buraxılış (GitHub)
- İctimai repo: `github.com/azadaydinli/Papiro`. İmzasız (ad-hoc) paylanır; ilk quraşdırmada "Yenə də aç" lazımdır (README).
- `./release.sh 1.0.3 notes.txt` (buraxılış qeydləri türkcə və ingiliscə yazılır): versiya + build nömrəsi, `Papiro.dmg` (insanlar üçün), `Papiro.zip` + `.sha256`
  (yeniləyici üçün), GitHub-da `v1.0.1` release. Endirmə linki: `releases/latest/download/Papiro.dmg`.
- Lokal git tarixçəsi GitHub-a **göndərilmir**: hər buraxılışda cari ağac GitHub-ın `main`-i üzərinə tək commit kimi
  gedir, müəllif GitHub noreply ünvanıdır. `git push` etmə; yalnız `release.sh`.
- Yeniləyici (`Updater`) `Bundle.main.bundleURL`-i əvəz edir; Masaüstündəki `build.noindex` nüsxəsi özü yoxlamır.

## Quruluş (`Sources/`)
| Fayl | Nə edir |
|---|---|
| `Localize.swift` | `L("…")`: ingiliscə mətn açardır, türkcəsi `Resources/tr.lproj/Localizable.strings`-dən gəlir |
| `main.swift` | Proqramın başlanğıcı, menyular, "Faylları birləşdir" |
| `Updater.swift` | GitHub Releases-dən yeniləmə: gündə bir dəfə yoxlama, bildiriş, Papiro.zip + SHA-256 yoxlaması, əvəzetmə və yenidən açılış |
| `Welcome.swift` | Başlanğıc pəncərəsi (Papiro faylsız açılanda və ya Dock-dan çağırılanda): "Aç" və "Son baxılanlar". Papiro fayl ilə açılanda (Finder-də iki klik, PDF-lərin default proqramı) görünmür: Finder-in verdiyi faylları `AppDelegate.application(_:open:)` açır və qeyd edir. Pəncərəni bağlamaq (x, ⌘W) yalnız sənədi bağlayır, Papiro açıq qalır (Mac proqramları kimi); son sənəd bağlananda pəncərə qalmır, Dock ikonuna klik bu pəncərəni açır |
| `PDFDoc.swift` | `NSDocument`: PDF, səhifə əməliyyatları (`perform` → geri alınır), Böl işarələri (`groups`), diskdəki sıra (`diskIndex`) |
| `Marks.swift` | `MarkStore`: yarımçıq işarələmənin bərpası üçün işarələrin yerli müvəqqəti saxlanması |
| `DocWindowController.swift` | Pəncərə: üst bar, alətlər barı, sol panel, sağda imza paneli (inspector), rejimlər (`page`, `grid`, `split`, `margins`, `marginsApply`, `whiteout`, `text`, `highlight`), bütün əmrlər |
| `Sidebar.swift` | Sol panel (`PageSidebar`, öz `NSCollectionView`-u): Önizleme kimi səhifəni izləyir: cari səhifə görünüşün ortasındakı səhifədir (`shownPage`, sürüşmə zamanı hər addımda; PDFKit-in cari səhifəsi yalnız sürüşmə dayananda dəyişir), seçilir və kiçik şəkli görünməyəndə siyahı yumşaq sürüşüb onu ən yaxın kənara gətirir (`follow`); kiçik şəklə klikdə siyahı tərpənmir; səhifələrin cari görüntüsü (döndərilmiş, mətn / imza ilə), Önizleme kimi seçim fonu, ⌘/⇧ ilə bir neçə səhifə (Sil, İxrac et, Döndər onlara aiddir), sağ klik menyusu, sürükləyib yerini dəyişmək |
| `PageGrid.swift` | Səhifələr şəbəkəsi, Böl rejimində toplu vərəqlər (stack) və yığılma animasiyası, Shift+klik, "Tətbiq et" checkbox-ları |
| `SplitPanel.swift` | "Faylları yaz": qovluq, nömrələmə (qovluqdakı ən böyük nömrədən davam), fonda yazma, `.partial`, "Dayandır" |
| `Margins.swift` | "Kənarları təmizlə": məzmunun avtomatik tapılması (deşiklər və küncdəki nömrələr xaric), ağartma |
| `Redact.swift` | "Ağart": əl ilə çəkilən düzbucaqlıların ağardılması |
| `Annotate.swift` | "Mətn" (FreeText qutuları, `TextOverlay`) və "İmza" (sağ panel `SignaturePanel`, PNG-lər `~/Library/Application Support/Papiro/Signatures/`-də, `ImageAnnotation` Stamp); geri alınan `swapAnnotation` / `movedAnnotation` |
| `Highlight.swift` | "Vurgula" (Önizleme kimi kapsul: qələm, ayırıcı, ox. Alətlər barının digər düymələri kimi tək bir `.glass` düymədir (eyni rəng, üzərinə gəlmə, basılanda böyümə, "on" halında mavi), şəkli şablondur (`highlightImage`); sol yarısına klik aləti açır/bağlayır, sağ yarısına (ox) klik stilləri açır (`SplitButton.clickedRight`); eni 74 nöqtə — şüşə Önizleme-dəki kimi 72,5 görünür. Üst barın effektlərini yalnız `NSToolbar` çəkir: `.toolbar` bezel alətlər barında mavi çıxır və effekti olmur, ona görə alətlər barında hamısı `.glass`-dır): rəng (sarı, yaşıl, mavi, çəhrayı, bənövşəyi), altdan və ya üstdən xətt; seçilən mətnin hər sətri bir PDF annotasiyası (Highlight / Underline / StrikeOut), bir addımda geri alınır; sağ klik: "Remove Highlight" (tr: "Vurguyu Kaldır") |
| `Continuity.swift` | "iPhone’dan İçe Aktar" (Continuity Camera): "+" menyusunda (Belge Tara / Fotoğraf Çek / Çizim Ekle → cari səhifədən sonra səhifə; iPhone skanı A4-ün ortasına qoyur — səhifə şəklin çərçivəsinə kəsilir, `Scan.pictureFrame`; foto/çizim A4-ə sığdırılır) və imza panelinin "+"-ında (şəkil → kağız şəffaf, mürəkkəb qalır → imza). macOS bu bəndi yalnız ana menyuda doldurur: Dosya menyusunda gizli bir bənd durur (`DeviceImport.holder`), "+" menyuları onu açıq olduqları müddətdə götürür (`DeviceImport.popUp`). Növlər `NSApp.registerServicesMenuSendTypes` ilə qeydiyyatdadır, qəbul `DocWindowController.readSelection` |
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
- `groups` diskdəki faylın səhifə sırasına görədir; uğurlu saxlamadan sonra (avtomatik saxlama — `.autosaveInPlaceOperation` —
  daxil) yeni fingerprint ilə yazılır, köhnə fayl silinir.
- Sənədlər avtomatik saxlanır (`PDFDoc.autosavesInPlace = true`): ⌘S lazım deyil, bağlayanda sual yoxdur.
- İşarə əməliyyatları geri alınır, amma sənədi "dəyişdirilib" etmir (`PDFDoc.updateChangeCount`).

## Yoxlama
- Məntiq: `Sources/` (main.swift-dən başqa) + kiçik test `main.swift` ilə ayrıca `swiftc` proqramı yığılıb işə salınır
  (`PDFDoc`, `MarkStore`, `Margins` birbaşa çağırılır). Test faylları müvəqqəti qovluqda saxlanır və sonda silinir;
  testin yaratdığı işarə faylları da silinir.
- UI: proqram açılır və ekranda yoxlanılır. Ekran kilidli olanda: test `main.swift` `PDFDoc` + `DocWindowController` açır,
  rejimləri dəyişir və pəncərəni `cacheDisplay` ilə PNG-yə çəkir (animasiyalar orada işləmir).
- Böl-ün etibarlılığı üzrə texniki tapşırıq (T0–T4) icra olunub; sənəd qovluqdan silinib, git tarixçəsində qalır
  (`git show e6d802a:TEXNIKI-TAPSIRIQ.md`).
