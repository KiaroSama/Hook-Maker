# راهنمای Hook Maker

ابزار ساخت، نصب و مدیریت هوک‌های Claude Code و Codex — به‌همراه هوک آماده‌ی همگام‌سازی دانش بین‌پروژه‌ای. هیچ مسیر پروژه‌ای داخل اسکریپت ثابت نشده است. تمام مسیرها، ارتباط‌ها، رویدادها و قوانین از فایل `sync-hooks.json` خوانده می‌شوند. فایل اصلی فقط یک نمونه غیرفعال و عمومی دارد و هیچ مسیر شخصی در آن ثبت نشده است.

## ساختار پوشه‌ها

| مسیر | نقش |
| --- | --- |
| `run.ps1` | لانچر — تنها اسکریپت ریشه. با دبل‌کلیک، اول Windows Terminal، بعد PowerShell 7، بعد PowerShell 5 |
| `sync-hooks.json` | کانفیگ مسیریابی (profileها و routeها) |
| `hooks\` | همه‌ی هوک‌ها — موتور سینک (`CrossProjectSyncHook.ps1`)، هوک آماده‌ی `GitSyncCheck.ps1` و هر هوک دلخواهی که بسازی |
| `scripts\` | ویزارد، نصاب، اعتبارسنج و تست موتور |
| `examples\` | قالب‌های profile |
| `logs\` | لاگ اجراهای ویزارد (خودکار ساخته می‌شود، commit نمی‌شود) |

## منوی تعاملی و لانچر (روش پیشنهادی)

`run.ps1` را اجرا کن. اگر بیرون از Windows Terminal باشی و `wt.exe` نصب باشد، ویزارد در یک پنجره‌ی Windows Terminal باز می‌شود؛ وگرنه در همان کنسول با pwsh (یا PowerShell 5) اجرا می‌شود.

گزینه‌های منو:

1. **ساخت یا به‌روزرسانی گروه همگام‌سازی** — مسیر ریشه هر پروژه را یکی‌یکی وارد کن؛ دستورها: `done` پایان، `undo` حذف آخرین مورد، `0` بازگشت، `exit` خروج. حداقل دو پروژه لازم است؛ مسیر تکراری، ناموجود یا تو در تو رد می‌شود. بعد از خلاصه، Enter (پیش‌فرض y) اجرا را شروع می‌کند.
2. **ساخت یا نصب هوک دلخواه** — دو زیرگزینه دارد:
   - **ساخت هوک جدید (با قالب آماده):** اسم هوک را بده، یکی از پنج قالب را انتخاب کن، حداکثر یک سوال جواب بده و یک هوک کامل و کارا در `hooks\` ساخته می‌شود (و در صورت تایید همان‌جا نصب می‌شود):
     1. **Context note** — یک یادداشت ثابت (متنی که خودت می‌دهی) را در هر session/prompt به عامل تزریق می‌کند.
     2. **Prompt guard** — پیام‌هایی که کلمات ممنوعه (لیست خودت) دارند را بلاک می‌کند.
     3. **Tool logger** — هر فراخوانی ابزار را در یک فایل لاگ کنار هوک ثبت می‌کند.
     4. **Git sync check** — وقتی پروژه با ریموت گیتش سینک نیست هشدار می‌دهد (تغییرات commit نشده، کامیت‌های push/pull نشده، یا شاخه‌ی بدون upstream)؛ برای پروژه‌ی سینک یا غیر-گیت ساکت است و آفلاین با آخرین وضعیت مقایسه می‌کند.
     5. **Empty skeleton** — اسکلت کامنت‌گذاری‌شده برای منطق دلخواه خودت.
   - **نصب هوک موجود:** از بین `.ps1`های `hooks\` انتخاب کن، رویدادها را مشخص کن (SessionStart، UserPromptSubmit، لیست دلخواه و ...)، پروژه‌های هدف را بده؛ در همه نصب می‌شود.

   قالب ۴ همان `hooks\GitSyncCheck.ps1` آماده هم هست. در ویزارد، `0` یک سوال به عقب برمی‌گردد و `exit` خارج می‌شود؛ منو دیگر برای Enter مکث نمی‌کند.
3. **نمایش profileهای موجود**
4. **اعتبارسنجی کانفیگ**

نکته‌های ویزارد:

- شناسه profile از هش مسیرهای مرتب‌شده ساخته می‌شود؛ اجرای دوباره با همان مسیرها همان profile را به‌روزرسانی می‌کند و وضعیت sync حفظ می‌شود.
- ویزارد پوشه `.ai` هر پروژه را در صورت نبودن می‌سازد؛ پوشه‌های `.claude` و `.codex` پروژه‌ها هم اگر نباشند خودکار ساخته می‌شوند.
- لاگ هر اجرا در پوشه `logs` با نام `Setup-SyncGroup_YYYY-MM-DD_HH-mm-ss_UTC.log` ذخیره می‌شود (سطح‌ها: DEBUG/INFO/WARNING/ERROR/CRITICAL، زمان UTC). همه ورودی‌های کاربر هم در لاگ ثبت می‌شوند.
- سوییچ `-NoInstall` فقط کانفیگ را می‌نویسد و نصب hook را انجام نمی‌دهد.

## هوک کجا نصب می‌شود و کانفیگش را از کجا می‌خواند (سطح پروژه)

نصب به‌صورت «داخل پروژه» است، نه سراسری:

- Claude آن را از `<پروژه>\.claude\settings.local.json` می‌خواند (این فایل خودکار git-ignore می‌شود؛ چون دستور شامل مسیر مطلق ماشین توست و نباید commit شود).
- Codex آن را از `<پروژه>\.codex\hooks.json` می‌خواند (فقط بعد از trust با دستور `/hooks` داخل همان پروژه بارگذاری می‌شود).
- هر دو entry به موتور `hooks\CrossProjectSyncHook.ps1` و فایل مسیریابی `sync-hooks.json` (با سوییچ `-ConfigPath`) اشاره می‌کنند. پس «کدام پروژه‌ها سینک شوند» را فقط `sync-hooks.json` تعیین می‌کند؛ فایل تنظیمات پروژه فقط «محل ثبت هوک» است.
- اگر فایل تنظیمات پروژه از قبل محتوای دیگری داشته باشد، دست نمی‌خورد: نصاب JSON موجود را می‌خواند، فقط hook را به آن اضافه می‌کند (بدون تکرار)، و قبل از نوشتن یک نسخه‌ی backup با پسوند تاریخ می‌سازد.
- نصب سراسری هم برای اسکریپت‌نویسی باقی مانده: `scripts\Install-Hook.ps1` بدون سوییچ `-TargetProject` روی `~/.claude/settings.json` و `~/.codex/hooks.json` می‌نویسد.

## فرمت hook در Claude و Codex

- **Claude Code:** زیر کلید `hooks`؛ `timeout` بر حسب ثانیه است و matcher رویداد SessionStart مقادیر `startup|resume|clear|compact` را می‌پذیرد.
- **Codex CLI:** رسمی از hooks پشتیبانی می‌کند، فایل `hooks.json` با همان ساختار `{"hooks": {...}}`. فیلد `commandWindows` مخصوص ویندوز و رسمی است. بعد از نصب حتماً `/hooks` را بزن و hook را trust کن.
- منبعی که پوشه `.ai` خالی دارد، بی‌صدا baseline می‌شود و بسته بازبینی خالی نمی‌سازد.

## ساخت هوک دلخواه

سینک `.ai` فقط یکی از هوک‌هاست. هر هوک یک اسکریپت در پوشه‌ی `hooks\` است که یک JSON از stdin می‌خواند و در صورت نیاز یک JSON روی stdout چاپ می‌کند. نمونه‌ی حداقلی (`hooks\MyHook.ps1`):

```powershell
$e = [Console]::In.ReadToEnd() | ConvertFrom-Json
# $e.hook_event_name و $e.cwd و $e.session_id و فیلدهای رویداد (مثل $e.prompt) در دسترس‌اند.
exit 0                       # اگر حرفی نداری
# یا برای تزریق context:
@{ hookSpecificOutput = @{ hookEventName = $e.hook_event_name; additionalContext = 'متن' } } |
    ConvertTo-Json -Depth 5 -Compress
```

فایل را در `hooks\` بگذار و از منوی لانچر گزینه ۲ را بزن — خودش در پروژه‌های هدف نصبش می‌کند. اگر کانفیگ خواست، مثل `sync-hooks.json` یک JSON جدا کنارش بگذار.

### هوک آماده: GitSyncCheck (چک سینک با گیت‌هاب)

`hooks\GitSyncCheck.ps1` از قبل آماده است: روی رویداد SessionStart نصبش کن (منو گزینه ۲ → نصب هوک موجود). هر بار که پروژه‌ای را باز کنی که با ریموتش (گیت‌هاب) سینک نیست، قبل از شروع کار به عامل گفته می‌شود:

- تغییرات commit نشده در working tree
- کامیت‌های push نشده (AHEAD)
- کامیت‌های pull نشده (BEHIND)
- شاخه‌ای که هرگز push نشده (بدون upstream)

پروژه‌ی سینک‌شده یا غیر-گیت → کاملاً ساکت. اگر اینترنت نباشد، با آخرین وضعیت شناخته‌شده‌ی ریموت مقایسه می‌کند و همین را هم اعلام می‌کند.

## مفاهیم اصلی

### ۱. Profile

هر profile یک hook منطقی مستقل است. می‌تواند قوانین، رویدادها و چند route مخصوص خودش را داشته باشد.

### ۲. Route

هر route یک جهت انتقال اطلاعات را مشخص می‌کند: `source -> destination`

برای ارتباط دوطرفه باید دو route تعریف شود. این کار عمداً صریح است تا هیچ پروژه‌ای به‌اشتباه منبع یا مقصد فرض نشود.

### ۳. گروه همگام‌سازی (full mesh)

ویزارد برای N پروژه، N×(N-1) route می‌سازد؛ یعنی هر پروژه مقصدِ همه‌ی پروژه‌های دیگر است و حافظه‌ی همه همیشه سینک می‌ماند.

## ویرایش sync-hooks.json

ساختار اصلی:

```json
{
  "version": 2,
  "defaults": { },
  "profiles": [ ]
}
```

برای ساخت profile دستی، نمونه داخل `sync-hooks.json` یا `examples/profile-template.json` را کپی کن و موارد زیر را عوض کن (تنظیم آماده‌ی دو ربات قبلی هم جداگانه در `examples/telegram-bots-profile.json` هست):

- `id`: شناسه یکتا و ثابت، فقط با حروف انگلیسی، عدد، خط تیره یا زیرخط
- `name`: نام نمایشی
- `enabled`: فعال یا غیرفعال
- `events`: رویدادهای اجرای profile
- `initialSyncMode`: رفتار اجرای اول
- `reviewInstructions`: قوانین اختصاصی بررسی
- `routes`: مسیرهای انتقال

نمونه‌ی route یک‌طرفه:

```json
{
  "id": "source-to-destination",
  "enabled": true,
  "source": {
    "name": "Source Project",
    "root": "D:\\Projects\\Source Project",
    "directory": ".ai",
    "aliases": []
  },
  "destination": {
    "name": "Destination Project",
    "root": "D:\\Projects\\Destination Project",
    "directory": ".ai",
    "aliases": []
  }
}
```

برای دوطرفه‌شدن، route دوم را با source و destination معکوس اضافه کن.

### چند منبع برای یک مقصد

سه route مستقل بساز: `A -> D` و `B -> D` و `C -> D`. وقتی عامل داخل Project D شروع به کار کند، هر سه route بررسی می‌شوند. فقط منبعی که نسبت به آخرین acknowledgement تغییر واقعی داشته باشد وارد context می‌شود.

### aliases

اگر یک پروژه از چند مسیر باز می‌شود، مسیرهای جایگزین را در aliases بنویس (متغیرهای محیطی ویندوز پشتیبانی می‌شوند):

```json
"aliases": [
  "D:\\Worktrees\\Project A",
  "%USERPROFILE%\\Projects\\Project A"
]
```

### initialSyncMode

- `review`: در اولین اجرا تمام فایل‌های مجاز منبع به‌عنوان بسته اولیه برای بررسی ارائه می‌شوند.
- `baseline`: در اولین اجرا فقط fingerprint ثبت می‌شود و چیزی به مدل فرستاده نمی‌شود. فقط تغییرات بعدی بررسی می‌شوند.

## قانون عدم اتلاف وقت

هر route وضعیت مستقل دارد. در هر اجرا ابتدا fingerprint سریع از مسیر نسبی، حجم و زمان تغییر فایل‌ها ساخته می‌شود:

- اگر fingerprint با آخرین وضعیت پردازش‌شده یکسان باشد، اسکریپت بدون خروجی تمام می‌شود.
- اگر فقط timestamp تغییر کرده باشد، SHA-256 بررسی می‌شود و در صورت یکسان‌بودن محتوا چیزی به مدل ارسال نمی‌شود.
- هش کامل فقط وقتی محاسبه می‌شود که fingerprint سریع تغییر کرده باشد.
- یک pending review در همان session فقط یک‌بار نمایش داده می‌شود.
- پوشه `.cross-project-sync` از بررسی حذف است و حلقه ایجاد نمی‌کند.

## گزینه‌های قابل override

این گزینه‌ها را می‌توان در defaults، profile یا route قرار داد. مقدار route بالاترین اولویت را دارد:

`events`، `initialSyncMode`، `maxFileBytes`، `includeExtensions`، `excludePatterns`، `reviewInstructions`

## نصب دستی (بدون ویزارد)

نصب داخل یک پروژه (همان کاری که ویزارد می‌کند):

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -Profile "<profile-id>" -TargetProject "<مسیر پروژه>"
```

نصب سراسری همه profileها با یک hook:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1"
```

فقط Claude یا فقط Codex: سوییچ `-ClaudeOnly` یا `-CodexOnly` را اضافه کن.

نصب هوک دلخواه بدون ویزارد:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -CustomHook ".\hooks\MyHook.ps1" -Events SessionStart,UserPromptSubmit -TargetProject "<مسیر پروژه>"
```

اعتبارسنجی کانفیگ:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Validate-Config.ps1"
```

تست موتور (۱۸ سنجش، زیر pwsh و PowerShell 5.1):

```powershell
pwsh -NoLogo -NoProfile -File ".\scripts\Test-Engine.ps1"
```

## نکته‌ها

- بعد از تغییر id یک profile یا route، وضعیت قبلی دیگر به آن وصل نیست و route به‌عنوان یک route جدید شناخته می‌شود. بنابراین idها را پس از شروع استفاده ثابت نگه دار.
- محل وضعیت و بسته‌های موقت در `destination.directory` ساخته می‌شود: `‎.ai\.cross-project-sync\state` و `‎.ai\.cross-project-sync\inbox`. این مسیر باید در ignore rules قرار بگیرد و نباید commit شود.
- اگر می‌خواهی هر profile در `/hooks` به‌صورت command جدا دیده شود، `Install-Hook.ps1` را یک‌بار برای هر profile با پارامتر `-Profile` اجرا کن.
- این نرم‌افزار رایگان نیست — همه‌ی حقوق محفوظ است (فایل `LICENSE`).
