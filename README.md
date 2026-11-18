# Papiro

macOS üçün PDF oxuyucu və redaktor. Əsas işi skan edilmiş cildi ayrı-ayrı sənədlərə parçalamaqdır
(`Document_0001.pdf`, `Document_0002.pdf` …). Bundan əlavə:

- səhifələri döndərmək, əlavə etmək, silmək, ayrıca fayl kimi çıxarmaq, faylları birləşdirmək;
- skan edilmiş səhifələrdə kənarları (deşik izləri, ləkələr) və lazımsız hissələri həqiqətən silmək;
- səhifəyə mətn yazmaq və PNG imza qoymaq;
- mətndə axtarış.

## Endirmək

**[Papiro.dmg — son versiya](https://github.com/azadaydinli/Papiro/releases/latest/download/Papiro.dmg)**

Tələb: macOS 26 və ya daha yeni.

## Quraşdırmaq

1. `Papiro.dmg` faylını açın və **Papiro**-nu **Applications** qovluğuna sürükləyin.
2. Papiro Apple tərəfindən imzalanmayıb, ona görə ilk dəfə macOS onu açmağa icazə vermir:
   - Papiro-nu bir dəfə açmağa çalışın və xəbərdarlığı bağlayın;
   - **Sistem Ayarları → Məxfilik və Təhlükəsizlik** bölməsinin aşağısında Papiro üçün **“Yenə də aç”** düyməsini basın;
   - açılan sualda yenə **“Aç”** seçin.

   Bu, yalnız ilk quraşdırmada lazımdır.

## Yeniləmələr

Yeni versiya çıxanda Papiro özü bildiriş göstərir (gündə bir dəfə yoxlayır, menyuda **Papiro → Yeniləmələri yoxla…**
də var). **“Yenilə”** basanda yeni versiya yüklənir, yoxlanılır, quraşdırılır və Papiro yenidən açılır.
Yoxlama zamanı GitHub-a yalnız son versiyanın sorğusu gedir; sənədləriniz və onlar haqqında heç bir məlumat
göndərilmir.

## Yığmaq (tərtibatçılar üçün)

```
./build.sh                      # build.noindex/Papiro.app
./release.sh 1.0.1 qeydler.txt    # yeni versiyanı GitHub-da buraxmaq
```
