راهنمای نسخه قابل تنظیم Cross-Project Sync Hook

این نسخه هیچ مسیر پروژه‌ای را داخل اسکریپت ثابت نکرده است. تمام مسیرها، ارتباط‌ها، رویدادها و قوانین از فایل sync-hooks.json خوانده می‌شوند. فایل اصلی فقط یک نمونه غیرفعال و عمومی دارد و هیچ مسیر شخصی در آن ثبت نشده است.

منوی تعاملی و لانچر (روش پیشنهادی)

run.ps1 را اجرا کن (خودش PowerShell 7 را ترجیح می‌دهد). گزینه 1 یک «گروه همگام‌سازی» می‌سازد:

1. مسیر ریشه هر پروژه را یکی‌یکی وارد کن. دستورها: done پایان، undo حذف آخرین مورد، cancel انصراف.
2. حداقل دو پروژه لازم است؛ مسیر تکراری، ناموجود یا تو در تو رد می‌شود.
3. خلاصه نمایش داده می‌شود و Enter (پیش‌فرض Y) اجرا را شروع می‌کند.
4. ویزارد پوشه .ai هر پروژه را در صورت نبودن می‌سازد، یک profile تمام‌مسیره (هر پروژه مقصدِ همه پروژه‌های دیگر) در sync-hooks.json می‌نویسد، کانفیگ را اعتبارسنجی می‌کند و hook را «داخل خودِ هر پروژه» نصب می‌کند (نه سراسری).

نکته‌های ویزارد:
- شناسه profile از هش مسیرهای مرتب‌شده ساخته می‌شود؛ اجرای دوباره با همان مسیرها همان profile را به‌روزرسانی می‌کند و وضعیت sync حفظ می‌شود.
- لاگ هر اجرا در پوشه logs با نام Setup-SyncGroup_YYYY-MM-DD_HH-mm-ss_UTC.log ذخیره می‌شود (سطح‌ها: DEBUG/INFO/WARNING/ERROR/CRITICAL، زمان UTC).
- سوییچ -NoInstall فقط کانفیگ را می‌نویسد و نصب hook را انجام نمی‌دهد.
- گزینه 2 منو profileهای موجود را نشان می‌دهد و گزینه 3 کانفیگ را اعتبارسنجی می‌کند.

هوک کجا نصب می‌شود و کانفیگش را از کجا می‌خواند (سطح پروژه)

نصب به‌صورت «داخل پروژه» است، نه سراسری:
- Claude آن را از <پروژه>\.claude\settings.local.json می‌خواند (این فایل خودکار git-ignore می‌شود؛ چون دستور شامل مسیر مطلق ماشین توست و نباید commit شود).
- Codex آن را از <پروژه>\.codex\hooks.json می‌خواند (فقط بعد از trust با دستور /hooks داخل همان پروژه بارگذاری می‌شود).
- هر دو entry به همان موتور scripts\CrossProjectSyncHook.ps1 و همان فایل مسیریابی sync-hooks.json (با سوییچ -ConfigPath) اشاره می‌کنند. پس «کدام پروژه‌ها سینک شوند» را فقط sync-hooks.json تعیین می‌کند؛ فایل تنظیمات پروژه فقط «محل ثبت هوک» است.
- نصب سراسری هم برای اسکریپت‌نویسی باقی مانده: scripts\Install-Hook.ps1 بدون سوییچ -TargetProject روی ~/.claude/settings.json و ~/.codex/hooks.json می‌نویسد.

فرمت hook در Claude و Codex

- Claude Code: زیر کلید hooks؛ timeout بر حسب ثانیه است و matcher رویداد SessionStart مقادیر startup|resume|clear|compact را می‌پذیرد.
- Codex CLI: رسمی از hooks پشتیبانی می‌کند، فایل hooks.json با همان ساختار {"hooks": {...}}. فیلد commandWindows مخصوص ویندوز و رسمی است. بعد از نصب حتماً /hooks را بزن و hook را trust کن.
- منبعی که پوشه .ai خالی دارد، بی‌صدا baseline می‌شود و بسته بازبینی خالی نمی‌سازد.

ساخت هوک دلخواه

سینک .ai فقط یکی از هوک‌هاست. هر هوک یک اسکریپت است که یک JSON از stdin می‌خواند و در صورت نیاز یک JSON روی stdout چاپ می‌کند. نمونه‌ی حداقلی (scripts\MyHook.ps1):

  $e = [Console]::In.ReadToEnd() | ConvertFrom-Json
  # $e.hook_event_name و $e.cwd و $e.session_id و فیلدهای رویداد (مثل $e.prompt) در دسترس‌اند.
  exit 0                       # اگر حرفی نداری
  # یا برای تزریق context:
  @{ hookSpecificOutput = @{ hookEventName = $e.hook_event_name; additionalContext = 'متن' } } |
      ConvertTo-Json -Depth 5 -Compress

سپس در <پروژه>\.claude\settings.local.json (و/یا <پروژه>\.codex\hooks.json) زیر رویداد دلخواه (SessionStart، UserPromptSubmit، PreToolUse، PostToolUse، Stop و ...) با همان ساختاری که این ابزار می‌نویسد ثبتش کن. اگر کانفیگ خواست، مثل sync-hooks.json یک JSON جدا کنارش بگذار. برای الگو، scripts\Test-Engine.ps1 نشان می‌دهد چطور یک هوک را انتها-به-انتها اجرا و تست کنی.

اجرای تست موتور

  pwsh -NoLogo -NoProfile -File .\scripts\Test-Engine.ps1

۱۸ assertion (چرخه‌ی بازبینی/ack، منبع خالی، پروژه‌ی نامرتبط، تک/چند پسوند) که هم زیر pwsh و هم زیر PowerShell 5.1 سبز می‌شوند.

مفاهیم اصلی

1. Profile
هر profile یک hook منطقی مستقل است. می‌تواند قوانین، رویدادها و چند route مخصوص خودش را داشته باشد.

2. Route
هر route یک جهت انتقال اطلاعات را مشخص می‌کند:
source -> destination

برای ارتباط دوطرفه باید دو route تعریف شود. این کار عمداً صریح است تا هیچ پروژه‌ای به‌اشتباه منبع یا مقصد فرض نشود.

3. یک hook سراسری یا چند hook مستقل
دو روش داری:

الف) یک hook سراسری نصب کن و پارامتر Profile را نده. اسکریپت تمام profileهای فعال را بررسی می‌کند، اما فقط routeهایی را اجرا می‌کند که مقصدشان پروژه فعلی است.

ب) برای هر profile یک hook جدا نصب کن:

powershell.exe -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -Profile "telegram-bots-ai"

سپس برای profile بعدی همان دستور را با id دیگر اجرا کن.

ویرایش sync-hooks.json

ساختار اصلی:

{
  "version": 2,
  "defaults": { ... },
  "profiles": [ ... ]
}

برای ساخت hook جدید، profile نمونه داخل sync-hooks.json یا examples/profile-template.json را کپی کن و موارد زیر را عوض کن:

تنظیم آماده مربوط به دو ربات قبلی نیز جداگانه در examples/telegram-bots-profile.json قرار دارد و بخشی از کانفیگ اصلی نیست.

- id: شناسه یکتا و ثابت، فقط با حروف انگلیسی، عدد، خط تیره یا زیرخط
- name: نام نمایشی
- enabled: فعال یا غیرفعال
- events: رویدادهای اجرای profile
- initialSyncMode: رفتار اجرای اول
- reviewInstructions: قوانین اختصاصی بررسی
- routes: مسیرهای انتقال

ساخت route یک‌طرفه

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

برای دوطرفه‌شدن، route دوم را با source و destination معکوس اضافه کن.

ساخت چند منبع برای یک مقصد

سه route مستقل بساز:

Project A -> Project D
Project B -> Project D
Project C -> Project D

وقتی عامل داخل Project D شروع به کار کند، هر سه route بررسی می‌شوند. فقط منبعی که نسبت به آخرین acknowledgement تغییر واقعی داشته باشد وارد context می‌شود.

قابلیت aliases

اگر یک پروژه از چند مسیر باز می‌شود، مسیرهای جایگزین را در aliases بنویس:

"aliases": [
  "D:\\Worktrees\\Project A",
  "%USERPROFILE%\\Projects\\Project A"
]

متغیرهای محیطی ویندوز پشتیبانی می‌شوند.

initialSyncMode

review:
در اولین اجرا تمام فایل‌های مجاز منبع به‌عنوان بسته اولیه برای بررسی ارائه می‌شوند.

baseline:
در اولین اجرا فقط fingerprint ثبت می‌شود و چیزی به مدل فرستاده نمی‌شود. فقط تغییرات بعدی بررسی می‌شوند.

قانون عدم اتلاف وقت

هر route وضعیت مستقل دارد. در هر اجرا ابتدا fingerprint سریع از مسیر نسبی، حجم و زمان تغییر فایل‌ها ساخته می‌شود.

- اگر fingerprint با آخرین وضعیت پردازش‌شده یکسان باشد، اسکریپت بدون خروجی تمام می‌شود.
- اگر فقط timestamp تغییر کرده باشد، SHA-256 بررسی می‌شود و در صورت یکسان‌بودن محتوا چیزی به مدل ارسال نمی‌شود.
- هش کامل فقط وقتی محاسبه می‌شود که fingerprint سریع تغییر کرده باشد.
- یک pending review در همان session فقط یک‌بار نمایش داده می‌شود.
- پوشه .cross-project-sync از بررسی حذف است و حلقه ایجاد نمی‌کند.

گزینه‌های قابل override

این گزینه‌ها را می‌توان در defaults، profile یا route قرار داد. مقدار route بالاترین اولویت را دارد:

- events
- initialSyncMode
- maxFileBytes
- includeExtensions
- excludePatterns
- reviewInstructions

نصب همه profileها با یک hook

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1"

نصب فقط یک profile

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -Profile "telegram-bots-ai"

فقط Claude

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -ClaudeOnly

فقط Codex

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Install-Hook.ps1" -CodexOnly

اعتبارسنجی کانفیگ

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Validate-Config.ps1"

بعد از تغییر id یک profile یا route، وضعیت قبلی دیگر به آن وصل نیست و route به‌عنوان یک route جدید شناخته می‌شود. بنابراین idها را پس از شروع استفاده ثابت نگه دار.

محل وضعیت و بسته‌های موقت

در destination.directory ساخته می‌شود:

.ai\.cross-project-sync\state
.ai\.cross-project-sync\inbox

این مسیر باید در ignore rules قرار بگیرد و نباید commit شود.

نکته درباره ساخت چند hook واقعی

اگر یک hook سراسری بدون Profile نصب کنی، اضافه‌کردن profile جدید فقط با ویرایش sync-hooks.json انجام می‌شود و نیازی به تغییر settings Claude یا Codex نیست.

اگر می‌خواهی هر profile در /hooks به‌صورت command جدا دیده شود، Install-Hook.ps1 را یک‌بار برای هر profile با پارامتر -Profile اجرا کن.
