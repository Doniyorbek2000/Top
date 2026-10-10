<p align="center"><img src="mobile/assets/logo.png" width="120" alt="Sado"></p>

<h1 align="center">Sado</h1>

<p align="center">Android va iOS uchun Telegram klienti (Flutter + TDLib 1.8.68).<br>
Telegram'ning barcha chatlari, kanallari va guruhlari, ustiga Plus Messenger, Nicegram va iMe uslubidagi qo'shimcha imkoniyatlar.</p>

| Chatlar | Chat | Guruh va so'rovnoma | Menyu | Qorong'i mavzu |
|---|---|---|---|---|
| ![](mobile/test/screenshots/home.png) | ![](mobile/test/screenshots/chat.png) | ![](mobile/test/screenshots/group.png) | ![](mobile/test/screenshots/drawer.png) | ![](mobile/test/screenshots/home_dark.png) |

## Imkoniyatlar

**Telegram asoslari**
- Telefon raqam bilan kirish: SMS, Telegram ichidagi kod, qo'ng'iroq, Fragment, 2FA parol va uni tiklash, ro'yxatdan o'tish, email tasdiqlash
- QR kod orqali kirish
- Barcha chatlar: shaxsiy chatlar, guruhlar, superguruhlar, kanallar, botlar, maxfiy chatlar (o'qish), "Saqlangan xabarlar"
- Papkalar (Telegram bilan sinxronlanadi): yaratish, tahrirlash, tartiblash, tavsiya etilgan papkalar va har bir papka bo'yicha o'qilmaganlar soni
- Arxiv, chatni qadash, ovozsiz qilish, o'qilgan yoki o'qilmagan deb belgilash, chatni o'chirish yoki tark etish
- Xabarlar: matn (havola, mention, bold, code va spoiler entity'lari bilan), rasm, video, GIF, video-xabar, ovozli xabar (to'lqin shakli va pleyer bilan), audio, fayl, stiker, joylashuv, kontakt, so'rovnoma, qo'ng'iroq yozuvlari va servis xabarlar
- Javob berish, tahrirlash, forward qilish, nusxa olish, havolani nusxalash, pin qilish, bir yoki ikki tomonlama o'chirish, bir nechtasini tanlash, reaksiyalar, ikki marta bosib tezkor reaksiya
- Ovozli xabar yozish (bosib turing; chapga sursangiz bekor bo'ladi), galereya, kamera, fayl, joylashuv, so'rovnoma va kontakt yuborish
- Qoralamalar sinxronlanadi, "yozmoqda…" holati, onlayn holat va "o'qildi" belgilari
- O'qilmagan xabarga, javobga yoki qadalgan xabarga sakrash
- Global qidiruv: chatlar, ochiq kanal va guruhlar, xabarlar
- Profil va chat ma'lumotlari: bio, username, taklif havolasi, a'zolar, umumiy media, fayllar, havolalar, ovozli xabarlar va musiqa
- Guruh yoki kanal yaratish, nomi, tavsifi va rasmini tahrirlash, a'zo qo'shish yoki chiqarish
- Kontaktlar va telefon kontaktlarini sinxronlash
- Sozlamalar: profil, maxfiylik (onlayn holat, raqam, rasm, bio, qo'ng'iroqlar, guruhga taklif), bloklanganlar, faol seanslar (tugatish bilan), bildirishnomalar

**Sado qo'shimchalari**
- **Ghost rejim**: onlayn holat, "o'qildi" va "yozmoqda" yuborilmaydi
- **Telegram AI** (TDLib 1.8.68): xabarni tarjima qilish, uzun xabarning qisqacha mazmuni, matndagi xatolarni tuzatish, uslub bilan qayta yozish, emoji qo'shish, ovozli xabarni matnga aylantirish
- **Multi-akkaunt**: 5 tagacha hisob, menyudan bir zumda almashtiriladi
- Ko'rinish: 7 ta asosiy rang, yorug' yoki qorong'i mavzu, matn hajmi, xabar burchaklari
- 3 til: o'zbek, rus va ingliz
- Enter bilan yuborish, tezkor reaksiyani tanlash, tarjima tilini tanlash

## Tuzilishi

```
mobile/
  lib/core/tdlib/        TDLib JSON FFI: td_create_client_id/td_send/td_receive, alohida isolate'da qabul sikli
  lib/state/telegram.dart  TDLib update'lari asosidagi xotiradagi kesh (chatlar, foydalanuvchilar, fayllar, papkalar)
  lib/state/              Riverpod provayderlari, chat tarixi kontrolleri, amallar (yuborish, AI va h.k.)
  lib/features/           UI: auth, home, chat, profile, contacts, search, settings
  lib/l10n/               uz/ru/en tarjimalari
  tool/build_tdlib_*.sh   TDLib'ni manbadan yig'ish (Android NDK / iOS xcframework)
```

TDLib typed API klasslari [`tdlib_ex`](https://pub.dev/packages/tdlib_ex) 0.44.0 paketidan olinadi (TDLib `c15d3f5a5`, 1.8.68). FFI transport loyihaning o'zida yozilgan.

## Ishga tushirish

### 1. Telegram API kalitlari
[my.telegram.org/apps](https://my.telegram.org/apps) sahifasida `api_id` va `api_hash` oling. Ularni ikki usulda berish mumkin:
- yig'ish paytida: `--dart-define=TG_API_ID=... --dart-define=TG_API_HASH=...`
- yoki ilovaning birinchi ekranida kiritish (qurilmada xavfsiz saqlanadi)

### 2. TDLib native kutubxonasi

```bash
cd mobile
# Android: libtdjson.so → android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}
ANDROID_SDK_ROOT=$HOME/Android/Sdk tool/build_tdlib_android.sh
# iOS (macOS + Xcode; brew install gperf cmake coreutils): ios/TDLib/tdjson.xcframework
tool/build_tdlib_ios.sh
```

Birinchi yig'ish 1–2 soat oladi; natija `.gitignore` ga kiritilgan.

### 3. Yig'ish

```bash
cd mobile
flutter pub get
flutter run --dart-define=TG_API_ID=12345 --dart-define=TG_API_HASH=0123456789abcdef0123456789abcdef
flutter build apk --release --split-per-abi --dart-define=TG_API_ID=... --dart-define=TG_API_HASH=...
flutter build ipa --dart-define=TG_API_ID=... --dart-define=TG_API_HASH=...
```

Android release imzosi uchun `android/key.properties` faylini yarating (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`).

### CI (GitHub Actions)
`.github/workflows/mobile.yml` quyidagilarni bajaradi:
- `analyze` va `flutter test`, testlar haqiqiy Linux `libtdjson` bilan ishlaydi
- TDLib'ni Android uchun yig'adi va APK'larni artefakt sifatida chiqaradi
- TDLib'ni iOS uchun yig'adi va imzolanmagan IPA chiqaradi

TDLib kesh'lanadi. Repository secrets: `TG_API_ID`, `TG_API_HASH`, ixtiyoriy `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.

## Testlar

```bash
cd mobile
flutter analyze
TDJSON_PATH=/path/to/libtdjson.so flutter test        # FFI, avtorizatsiya oqimi, chat ro'yxati mantig'i
SADO_SCREENSHOTS=1 TDJSON_PATH=... flutter test test/screenshots_test.dart --update-goldens
```

## Hozircha yo'q

- **Push-bildirishnomalar**: ilova yopiq bo'lganda xabar kelishi uchun Firebase/APNs loyihasi va TDLib `registerDevice` kerak. Hozir ilova ochiq yoki fonda turganida lokal bildirishnomalar ishlaydi.
- **Ovozli va video qo'ng'iroqlar**: Telegram qo'ng'iroqlari `tgcalls`/WebRTC native integratsiyasini talab qiladi. Qo'ng'iroq yozuvlari ko'rsatiladi.
- Hikoyalar (stories), animatsion (TGS/WebM) stikerlar (ularning o'rniga eskiz ko'rsatiladi), forum mavzulari, to'lovlar, bot inline klaviaturalari.
