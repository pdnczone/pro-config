# pro-config

<div dir="rtl">

یک مجموعه کانفیگ حرفه‌ای و ضدفیلتر را **به پنل موجود شما اضافه می‌کند**. دو پنل پشتیبانی می‌شود:

| پنل | اسکریپت | راهنما |
|---|---|---|
| [3x-ui](https://github.com/MHSanaei/3x-ui) نسخه‌ی 3.x | `install-3xui.sh` | [بخش 3x-ui](#نصب-روی-3x-ui) |
| [Rebecca](https://github.com/rebeccapanel/Rebecca) | `install-rebecca.sh` | [بخش Rebecca](#برای-پنل-rebecca) (شامل OpenVPN) |

هیچ اینباند، کلاینت یا هاستی **حذف یا ویرایش نمی‌شود.**

## نصب (یک لینک برای همه)

روی سرور پنل، با کاربر root. اسکریپت خودش تشخیص می‌دهد Rebecca نصب است یا 3x-ui و نصب‌کننده‌ی درست را اجرا می‌کند:

</div>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh)
```

<div dir="rtl">

- اگر هر دو پنل روی یک سرور باشند، می‌پرسد کدام را می‌خواهید. با `--panel-type rebecca` یا `--panel-type 3x-ui` هم می‌توانید مستقیم انتخاب کنید.
- بقیه‌ی گزینه‌ها (مثل `--yes`، `--domain`، `--configs`) بدون تغییر به نصب‌کننده‌ی همان پنل می‌رسند.
- اگر خواستید، فایل هر پنل را مستقیم هم می‌توانید اجرا کنید: `install-3xui.sh` یا `install-rebecca.sh`.

## نصب روی 3x-ui

</div>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh)
```

<div dir="rtl">

اسکریپت به ترتیب این‌ها را می‌پرسد:

1. **ورود به پنل:** توکن API (از Settings › API Tokens)، یا نام کاربری و رمز پنل.
2. **دامنه‌ی شما:** دامنه‌ای که مستقیم به سرور اشاره می‌کند (در Cloudflare ابر **خاکستری**). اگر گواهی نداشته باشد، می‌تواند همان‌جا با Let's Encrypt گواهی بگیرد.
3. **دامنه‌ی CDN:** ساب‌دامینی که پشت Cloudflare است (ابر **نارنجی**) و حالت SSL/TLS آن **Full** است.
4. **کانفیگ‌ها:** از یک منو انتخاب می‌کنید (شماره‌ها با کاما، یا `all`).
5. **تعداد آی‌پی تمیز Cloudflare:** پیش‌فرض ۲۰.

در پایان، همه‌ی کانفیگ‌ها خودکار تست اتصال می‌شوند و لینک سابسکریپشن نمایش داده می‌شود.

## کانفیگ‌ها

| کانفیگ | توضیح |
|---|---|
| ⚡ Reality Vision | اصلی؛ سریع‌ترین و مخفی‌ترین |
| 🌀 Reality XHTTP | REALITY روی XHTTP با پدینگ |
| 🔷 Reality gRPC | |
| 🔐 TLS Vision | با گواهی واقعی، به‌همراه نسخه‌های 🧩 Fragment و 6️⃣ IPv6 |
| 🛰 TLS XHTTP | هم مستقیم و هم از طریق CDN |
| 🌐 CDN WS | از طریق Cloudflare، به‌همراه 🧊 آی‌پی‌های تمیز |
| 🔗 CDN HTTPUpgrade | از طریق Cloudflare |
| 🚄 Hysteria2 | روی UDP/QUIC، با FinalMask Salamander |
| 🧬 PQ Sudoku | VLESS پست‌کوانتومی با FinalMask Sudoku (آزمایشی) |
| 🛟 Shadowsocks-2022 | پشتیبان |

**FinalMask:**
- **Fragment:** روی کانفیگ‌های TLS و CDN، سمت کلاینت. ClientHello را تکه‌تکه می‌فرستد.
- **Salamander:** روی Hysteria2.
- **Sudoku:** روی PQ.

همه‌ی کانفیگ‌ها زیر **یک کلاینت جدید** با یک لینک سابسکریپشن قرار می‌گیرند. اگر IPv6 سرور کار کند، نسخه‌ی IPv6 هم ساخته می‌شود.

برای کانفیگ‌های دارای FinalMask از **سابسکریپشن JSON** و یک کلاینت با Xray-core نسخه‌ی 26 استفاده کنید (v2rayNG یا v2rayN جدید). Hysteria2 با Salamander در Hiddify و NekoBox هم کار می‌کند.

## اگر پورتی از قبل استفاده شده باشد

دو اینباند هیچ‌وقت نمی‌توانند روی یک پورت باشند. اسکریپت قبل از شروع، پورت همه‌ی اینباندهای پنل و همه‌ی برنامه‌های سرور را بررسی می‌کند. اگر پورتی پر باشد، می‌گوید **چه چیزی** از آن استفاده می‌کند و این گزینه‌ها را می‌دهد:

| گزینه | کار |
|---|---|
| `Enter` | پورت آزاد بعدی را خودش انتخاب می‌کند (پیشنهادی) |
| یک عدد | پورت دلخواه شما (اگر آن هم پر باشد، رد می‌شود) |
| `o` | **حالت Origin Rule** (فقط CDN): کلاینت روی پورت ۴۴۳ به Cloudflare وصل می‌شود و Cloudflare ترافیک را به یک پورت آزاد دلخواه روی سرور می‌فرستد |
| `s` | از این کانفیگ صرف‌نظر می‌شود؛ اینباند فعلی شما همان‌طور که هست می‌ماند |

نکته‌ها:

- **CDN:** Cloudflare فقط پورت‌های `443 2053 2083 2087 2096 8443` را پروکسی می‌کند. اگر همه‌ی آن‌ها پر باشند، از گزینه‌ی `o` استفاده کنید. اسکریپت در پایان قانون دقیق را چاپ می‌کند تا در Cloudflare، بخش Rules › Origin Rules، اضافه کنید:
  `Hostname = cdn… AND URI Path starts with /…  →  Destination port = …`
- **REALITY روی ۴۴۳:** اگر اینباند دیگری روی ۴۴۳ دارید، کانفیگ REALITY جدید روی پورت دیگری ساخته می‌شود. اگر می‌خواهید روی ۴۴۳ باشد، اینباند قبلی را خودتان در پنل به پورت دیگری منتقل کنید و اسکریپت را دوباره اجرا کنید.
- **حالت خودکار:** با `--ports auto` (یا `--yes`) همیشه پورت آزاد بعدی انتخاب می‌شود. کانفیگ CDN بدون پورت آزاد Cloudflare هم رد می‌شود.

## ایمنی

- قبل از هر تغییر، از دیتابیس پنل نسخه‌ی پشتیبان گرفته می‌شود: `/etc/x-ui/x-ui.db.bak-pro-*`
- هر اینباند تک‌تک اضافه می‌شود و بلافاصله بررسی می‌شود. اگر Xray آن را قبول نکند، فقط همان اینباند برگردانده می‌شود.
- تنظیمات عمومی پنل فقط در دو مورد تغییر می‌کند و هر دو فقط چیزی اضافه می‌کنند:
  - روشن کردن سابسکریپشن JSON.
  - تنظیم `remarkTemplate` روی `{{HOST}}` برای نام‌گذاری لینک‌ها. این مورد قبل از تغییر از شما پرسیده می‌شود.

## اجرای بدون سؤال

</div>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh) \
  --yes --token <API_TOKEN> --domain my.example.com --cdn cdn.example.com --configs all --clean 20
```

| option | |
|---|---|
| `--configs` | `all` or comma list: `rv,rx,rg,tv,tx,ws,hu,hy,pq,ss` |
| `--clean N` | number of Cloudflare clean-IP configs (0–30) |
| `--ports auto\|ask` | port-conflict behaviour |
| `--email E` | name of the new client |
| `--dry-run` | show the plan, change nothing |
| `--no-bbr`, `--no-test` | skip BBR / skip the connection test |

<div dir="rtl">

## آی‌پی‌های تمیز

لیست در [`clean-ips.txt`](clean-ips.txt) است. اسکریپت هر بار لیست را دانلود می‌کند، هر آدرس را از طریق Cloudflare با دامنه‌ی CDN **خود شما** تست می‌کند و آدرس‌های سالم را برمی‌دارد.

این آدرس‌ها از ۵ نود تست داخل ایران (دیتاسنترهای تهران) قابل دسترس بوده‌اند. ممکن است روی اینترنت همراه یا خانگی شما فرق داشته باشد. آدرس‌هایی که برای شما کار می‌کنند را با Pull Request اضافه کنید.

## نیازمندی‌ها

- 3x-ui نسخه‌ی **3.x**، یعنی نسخه‌ای که بخش‌های Clients و Hosts دارد.
- Xray-core نسخه‌ی **26.x**. برای FinalMask، Hysteria2 و PQ لازم است. اگر نباشد، این کانفیگ‌ها خودکار رد می‌شوند.
- Ubuntu یا Debian، با `python3`، `curl` و `openssl`.
- **فایروال:** پورت‌هایی که اسکریپت در پایان نشان می‌دهد را در فایروال سرویس ابری باز کنید (برای IPv4 و IPv6، و UDP برای Hysteria2).

</div>

---

<div dir="rtl">

## برای پنل Rebecca

همین کانفیگ‌ها را می‌شود روی پنل [Rebecca](https://github.com/rebeccapanel/Rebecca) هم ساخت. اسکریپت جدا است و چیزی از اینباند، هاست، سرویس و کاربر فعلی شما را حذف یا ویرایش **نمی‌کند**.

</div>

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pdnczone/pro-config/main/install.sh)
```

<div dir="rtl">

روی سرور پنل، با کاربر root اجرا کنید. اسکریپت نام‌کاربری و رمز یک ادمین `full_access` یا `sudo` را می‌پرسد (یا با `--token` توکن بدهید).

**چه می‌سازد:** اینباندهای جدید با تگ `pro-*`، هاست‌های همان‌ها، **یک سرویس جدید** که فقط همین هاست‌ها را دارد و **یک کاربر جدید** در آن سرویس. کاربران فعلی لینک تازه‌ای نمی‌گیرند.

| کانفیگ | امنیت |
|---|---|
| ⚡ Reality Vision / 🌀 XHTTP / 🔷 gRPC | `maxTimeDiff`، سه Short ID تصادفی، و امضای پساکوانتومی **ML-DSA-65** (با `--no-mldsa` خاموش می‌شود) |
| 🔐 TLS Vision، 🚄 Hysteria2 | فقط TLS 1.3، بدون پاسخ به SNI ناشناس |
| 🧬 PQ Sudoku | VLESS با احراز هویت **ML-KEM-768** + FinalMask Sudoku |
| 🌐 CDN WS / HTTPUpgrade / XHTTP | پشت Cloudflare، با Fragment و آی‌پی‌های تمیز |
| 🛡 **OpenVPN UDP / TCP** | `tls-crypt`، AES-256-GCM، TLS 1.3 در کلاینت، گواهی EC P-384 با CA اختصاصی (کلید CA دور ریخته می‌شود) |

OpenVPN را فقط زمانی انتخاب کنید که کلاینتی غیر از Xray دارید؛ فیلترینگ‌های پیشرفته آن را راحت‌تر از Reality تشخیص می‌دهند. نود در اولین استفاده خودش OpenVPN را نصب می‌کند (چند دقیقه).

**نکته‌ها**
- کانفیگ‌ها در کانفیگ مشترک `master` ساخته می‌شوند و Xray نود باید روی **همین سرور** باشد.
- TLS، CDN و Hysteria2 دامنه‌ی مستقیم با گواهی می‌خواهند. بدون دامنه فقط Reality، PQ و OpenVPN ساخته می‌شود.
- Shadowsocks-2022 در این نسخه نیست (Rebecca نمی‌تواند در زمان اجرا به آن کاربر اضافه کند).
- دیتابیس MySQL بکاپ خودکار ندارد؛ هر چه ساخته می‌شود جدید است و از داخل پنل پاک می‌شود.

</div>

## License

MIT
