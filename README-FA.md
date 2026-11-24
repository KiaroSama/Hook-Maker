<div align="center">

# Hook Maker

‏⁧**هوک‌های Claude Code و Codex CLI را در ویندوز بسازید، نصب کنید و مدیریت کنید.**⁩

[![GitHub Actions CI workflow on main](https://img.shields.io/badge/CI-GitHub%20Actions-16a34a)](.github/workflows/ci.yml)
[![Proprietary software license](https://img.shields.io/badge/license-Proprietary-2563eb)](LICENSE)
[![Release v1.0.0](https://img.shields.io/badge/release-v1.0.0-c2415b)](https://github.com/KiaroSama/Hook-Maker/releases/tag/v1.0.0)
[![PowerShell 7.6.10 and Windows PowerShell 5.1.26100.10068 measured locally](https://img.shields.io/badge/PowerShell-7.6.10%20%7C%205.1.26100.10068-8b5cf6)](.github/workflows/ci.yml)
[![Runs on Windows](https://img.shields.io/badge/platform-Windows-0891b2)](.github/workflows/ci.yml)
[![Launch the setup wizard with run.ps1](https://img.shields.io/badge/install-PowerShell%20wizard-4f46e5)](run.ps1)
[![Hook reference with events and configuration](https://img.shields.io/badge/docs-Hook%20reference-0284c7)](docs/HOOKS.md)
[![Measured size of tracked repository files in decimal megabytes](https://img.shields.io/badge/repo%20size-7.8%20MB-ca8a04)](README.md)
[![Registers hooks for Claude Code and Codex CLI](https://img.shields.io/badge/clients-Claude%20Code%20%7C%20Codex%20CLI-b45309)](docs/HOOKS.md)
[![Shipped hook count includes 30 packages and the sync engine](https://img.shields.io/badge/hooks-31%20shipped-15803d)](docs/HOOKS.md)
[![Cross-project knowledge sync lists changed source notes](https://img.shields.io/badge/sync-Knowledge%20sync-0d9488)](sync-hooks.example.json)
[![Read the registry and sync transaction contracts](https://img.shields.io/badge/registry-Transactional%20updates-334155)](docs/STORAGE-TRANSACTIONS.md)
[![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)

</div>

‏⁧[English](README.md) · [مرجع هوک‌ها](docs/HOOKS-FA.md) · [راهنمای مدیریت](docs/OPERATIONS-FA.md)⁩

## Hook Maker چه می‌کند؟

‏⁧۳۱ هوک همراه Hook Maker عرضه می‌شود: ۳۰ بستهٔ هوک و یک موتور همگام‌سازی دانش میان پروژه‌ها. ابزار راه‌اندازی هوک‌های انتخابی را در پوشهٔ هر پروژه نصب می‌کند و آن‌ها را برای یک یا هر دو کلاینت ثبت می‌کند. موتور همگام‌سازی مسیر یادداشت‌های مارک‌داون تغییرکرده را نشان می‌دهد. عامل پروژهٔ مقصد همان فایل‌ها را می‌خواند و تجربه‌های قابل استفاده را در حافظهٔ خودش ثبت می‌کند.⁩

## شروع کار

‏⁧به ویندوز، `PowerShell 7` (پیشنهادی) یا `Windows PowerShell 5.1` و کلاینتی که می‌خواهید استفاده کنید نیاز دارید. برای هوک‌های مربوط به Git، خود Git را هم نصب کنید. بعضی هوک‌ها ابزار جداگانه می‌خواهند؛ پیش از نصب، [مرجع هوک‌ها](docs/HOOKS-FA.md) را بخوانید.⁩

‏⁧در پوشهٔ Hook Maker، PowerShell را باز کنید و این فرمان را اجرا کنید:⁩

```powershell
.\run.ps1
```

1. ‏⁧گزینهٔ `1` را برای ساخت یا نصب هوک بزنید و سپس `1` را برای «نصب هوک موجود» بزنید.⁩
2. ‏⁧برای نصب یک هوک آن را انتخاب کنید، برای گروه همگام‌سازی `2` را بزنید و برای نصب گروه و همهٔ بسته‌های آماده `1` را بزنید. برای چند هوک از فهرست یا بازه‌ای مانند `3-8,20` استفاده کنید.⁩
3. ‏⁧Claude Code، Codex CLI یا هر دو را انتخاب کنید. مسیر پروژه‌ها را وارد کنید، رویدادها و مقصدها را بخوانید و نصب را تأیید کنید.⁩
4. ‏⁧کلاینت را دوباره باز کنید. در Codex با `/hooks` فرمان ثبت‌شده را بررسی کنید و پیش از استفاده آن را تأیید کنید.⁩

‏⁧هر هوک ابتدا رویدادهای پیشنهادی خودش را نشان می‌دهد. پس از نصب، پروژه نسخهٔ اجرایی خودش را دارد؛ تغییر فایل‌های Hook Maker نسخهٔ نصب‌شده را خودکار به‌روز نمی‌کند.⁩

## تنظیم هوک‌ها و همگام‌سازی

‏⁧هر بسته یک `.env.example` دارد. در پوشهٔ هوک از آن یک کپی با نام `.env` بسازید و `TARGET_PROJECTS` (مسیرها با جداکنندهٔ `;`)، `EVENTS` و `CLIENTS` (`Both`، `Claude` یا `Codex`) را تنظیم کنید. در منو `1` و بعد `3` را بزنید تا نصب از روی تنظیمات و بدون پرسش انجام شود. فایل تنظیمات محلی را وارد Git نکنید.⁩

‏⁧برای همگام‌سازی، یک گروه با دست‌کم دو مسیر ریشه بسازید. ابزار راه‌اندازی مسیرهای `sync-hooks.json` را طوری تنظیم می‌کند که هر عضو مسیر یادداشت‌های تغییرکردهٔ دیگر اعضا را ببیند. هوک فایلی کپی نمی‌کند و چیزی در پروژهٔ منبع نمی‌نویسد. [نمونهٔ تنظیمات](sync-hooks.example.json) و [راهنمای همگام‌سازی](docs/OPERATIONS-FA.md#sync-config) را ببینید.⁩

## مدیریت هوک‌های نصب‌شده

| گزینه | کاربرد |
| --- | --- |
| `33` | نسخه‌های نصب‌شده را به‌روز می‌کند و تغییرات را گزارش می‌دهد. |
| `34` | ثبت‌ها و فایل‌های نصب‌شده را بدون اجرای هوک بررسی می‌کند. |
| `35` | ثبت‌های انتخاب‌شده و فایل‌هایی را که Hook Maker مالک آن‌هاست حذف می‌کند. |
| `36` | فهرست گروه‌ها را نشان می‌دهد و پس از تأیید، همه را حذف می‌کند. هوک‌های نصب‌شده سر جایشان می‌مانند. |
| `37` | پروژهٔ تغییرنام‌یافته یا جابه‌جاشده را دوباره متصل می‌کند. |

‏⁧از پوشهٔ Hook Maker می‌توانید به‌روزرسانی گروهی را هم پیش‌نمایش کنید:⁩

```powershell
pwsh -NoProfile -File .\scripts\Update-Fleet.ps1 -WhatIf
```

‏⁧پیش‌نمایش وضعیت ثبت‌ها را نشان می‌دهد: به‌روز، قدیمی، نیازمند مهاجرت، دور از دسترس یا ردشده. پیش از اعمال تغییرات آن را بخوانید. برای به‌روزرسانی، حذف، محل فایل‌های اجرایی، گزارش‌ها و نمونهٔ هوک سفارشی به [راهنمای مدیریت](docs/OPERATIONS-FA.md) بروید.⁩

## رفع مشکل و منابع

- ‏⁧[مرجع هوک‌ها](docs/HOOKS-FA.md): رویدادها، تنظیمات و شیوهٔ گزارش هر هوک.⁩
- ‏⁧[بازیابی آزمون و به‌روزرسانی](docs/TEST-HOOK-RECOVERY.md): رسیدگی به کارهای متوقف یا ناقص. رکورد بازیابی قدیمی، موفقیت اجرای تازه را ثابت نمی‌کند.⁩
- ‏⁧[شواهد ورودی CI](docs/ci-input-evidence.md): بررسی بدون تغییر فایل‌هایی که گردش کار ممکن است بخواند.⁩
- ‏⁧[تراکنش‌های ذخیره‌سازی](docs/STORAGE-TRANSACTIONS.md) و [ادامهٔ کار](docs/TASK-CONTINUATION-CONTRACT.md): داده‌هایی که Hook Maker پس از خطا یا راه‌اندازی دوباره حفظ می‌کند.⁩

‏⁧گزارش‌های مدیریت با UTF-8 و زمان UTC در `logs/` نوشته می‌شوند. آن‌ها را محلی بررسی کنید و پیش از به‌اشتراک‌گذاری، مسیر پروژه و شناسهٔ حساب را بپوشانید. گزینه‌های گزارش و دورهٔ نگهداری در راهنمای مدیریت آمده‌اند.⁩

## مجوز

‏⁧نرم‌افزار اختصاصی است. [متن مجوز](LICENSE) را بخوانید.⁩

<a name="donate"></a>

## حمایت مالی

| ارز | شبکه | آدرس |
| --- | --- | --- |
| Bitcoin (BTC) | Bitcoin | `bc1qmth5m03pu5hujw5xw5jmywam3jj3sqwqupesdt` |
| USDT, BNB, USDC, etc. | BEP20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| USDT, TRX, USDC, etc. | TRC20 | `TWBA3xFTqgZAeAYMxqo85xWnzvty3DcAhw` |
| Ethereum (ETH) | ERC20 | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
| TON | TON | `UQCN8Umo_OfOWqImZetQsrNStPcmLkMAKajFyiCOhso23NDb` |
| Litecoin (LTC) | LTC | `ltc1qntqnnrunadurnw4cshv3qgspywrueyyeyngwuy` |
| Solana (SOL) | Solana | `7B2wkczUjmkDhETwQuknBL8sUsbuV7nErxc317TmQuwR` |
| Polygon (POL) | Polygon | `0x0Bd0BA443a8B9cf15922bf7f0Bb0a4b495fD06Ef` |
