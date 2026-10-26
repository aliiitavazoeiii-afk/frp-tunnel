# New Chat Prompt — Trust/Mieru/Naive/Maya4 Tunnel Project

Copy the prompt below into a new ChatGPT conversation.

---

من می‌خواهم پروژه‌ی VPN tunnel قبلی‌ام را دقیقاً از state فعلی ادامه بدهی.

Repository:

`aliiitavazoeiii-afk/frp-tunnel`

قبل از هر تحلیل یا تغییر، با GitHub connector خودت این فایل روی branch `main` را کامل بخوان:

`TUNNEL-PROJECT-HISTORY.md`

این فایل تاریخچه‌ی یکپارچه‌ی پروژه از Dual Trust/Mieru تا Triple Trust+Mieru+Naive و Maya4 Naive Lite است.

بعد بسته به کاری که ازت می‌خواهم branch مرتبط را fetch و current HEAD/version/scripts را دوباره بررسی کن. از memory یا README قدیمی برای runtime حدس نزن.

## Branch map

`trust-mieru-dual`
= production دو مسیره Trust + Mieru.

`triple-carrier-naive`
= معماری سه‌مسیره Trust + Mieru + Naive برای Maya3.

`maya3-multilane-naive`
= طراحی قدیمی‌تر Lane3/selective routing؛ canonical triple فعلی نیست مگر اینکه مشخصاً درباره آن branch صحبت کنیم.

`naive-mieru-dual`
= آزمایش جایگزینی Trust با Naive؛ deployed بودنش را فرض نکن.

`maya4-naive-lite`
= معماری مستقل و سبک Maya4 با فقط Naive + XUDP و x-ui v2.9.4.

## مهم‌ترین production rules

- runtime واقعی از documentation مهم‌تر است.
- هیچ وقت `pkill xray` نزن.
- هنگام تعویض foreign عادی x-ui را restart نکن.
- UUID/user configهای x-ui را regenerate نکن.
- private bundle، password، XUDP UUID، REALITY key یا secret را از من نخواه که paste کنم و داخل GitHub هم نگذار.
- قبل از cutover جدید، candidate test و rollback داشته باش.
- foreign قدیمی را تا تأیید کامل foreign جدید حذف نکن.
- برای خرابی یک carrier، carrier دیگر یا shared bridge را بی‌دلیل restart نکن.
- commandها را terminal-ready و copy/paste-safe بده.

## Dual Trust/Mieru

Branch:
`trust-mieru-dual`

آخرین baseline ثبت‌شده در history:
`VERSION 1.1.7`

معماری:

```
Users
 -> x-ui VLESS/REALITY :443
 -> dispatcher :7990
    -> Trust path :7991 -> direct carrier :7993
    -> Mieru path :7992 -> direct carrier :7994
```

UDP هر role از XUDP عبور می‌کند.

Dispatcher production:

```
strategy: sticky-sessions
interval: 120
lazy: true
max-failed-times: 2
```

Mieru:

```
MULTIPLEXING_OFF
HANDSHAKE_STANDARD
traffic-pattern empty
```

Role replacement باید مستقل باشد. خراب بودن Trust نباید مانع Replace Mieru شود و برعکس.

## Triple Trust + Mieru + Naive

Branch:
`triple-carrier-naive`

معماری:

```
:7990 unified dispatcher
  -> Trust :7991
  -> Mieru :7992
  -> Naive :7996

direct:
Trust :7993
Mieru :7994
Naive :7995
```

Naive TCP مستقیم از `:7995` و UDP از XUDP over Naive عبور می‌کند.

x-ui/public :443 نباید برای اضافه/حذف کردن Naive تغییر کند.

## Maya4 Naive Lite

Branch:
`maya4-naive-lite`

این را با Maya3 Triple قاطی نکن.

معماری:

```
Users
 -> 3X-UI / Xray :443
 -> SOCKS :7996
    TCP -> Naive :7995 -> Foreign :443
    UDP -> XUDP over same Naive carrier -> foreign loopback :2443
```

Services:

```
maya4-naive-client.service
maya4-xudp-router.service
x-ui.service
```

x-ui دقیقاً v2.9.4 است و نباید خودسرانه upgrade شود.

آخرین Maya4 helper یک dashboard دارد و entrypoint ترجیحی:

```bash
dual status
```

منو:

```
1) Replace foreign server (enter new IP only)
2) Full health check
3) Restart Maya4 tunnel only (x-ui untouched)
4) Recent tunnel warnings/errors
0) Exit
```

دامنه‌ی ثابت replacement Maya4:

`naive4.biya2film.top`

برای replacement آینده:

1. من A Record همین domain را روی IP foreign جدید می‌گذارم.
2. در ایران `dual status` و گزینه 1 را می‌زنم.
3. فقط IP جدید را وارد می‌کنم.
4. helper خودش SSH می‌زند، foreign را نصب می‌کند، bundle را می‌گیرد، candidate test روی 17995/17996 انجام می‌دهد، TCP و UDP/XUDP را چک می‌کند و فقط در صورت PASS cutover می‌کند.
5. x-ui نباید restart شود.
6. old foreign نباید خودکار حذف شود.

Direct form:

```bash
dual replace NEW_FOREIGN_IP
```

Health:

```bash
dual health
```

انتظار داریم:

```
OK maya4-naive-client
OK maya4-xudp-router
OK x-ui
OK Naive direct :7995
OK Naive full :7996
OK Telegram
OK UDP/XUDP
```

## آخرین bug مهم Maya4

Fresh foreign installer به دلیل Xray pin قدیمی `v26.9.8` با HTTP 404 fail می‌شد.

branch اصلاح شد و Xray به release معتبر `v26.10.21` با SHA256 رسمی pin شد.

بعد helper تعویض automatic ساخته شد و `dual status` به dashboard Maya4 وصل شد.

در شروع چت جدید اول این‌ها را اعلام کن:

1. `TUNNEL-PROJECT-HISTORY.md` را خواندی.
2. branch موردنیاز من را fetch کردی.
3. HEAD/version فعلی را گفتی.
4. safety invariantsی که حفظ می‌کنی را خیلی کوتاه گفتی.
5. اگر runtime verification لازم است، فقط حداقل commandهای read-only لازم را بده.

اگر live output فرستادم، همان خروجی را source of truth بگیر و بر اساسش ادامه بده.

---

Detailed source of truth for the historical handoff:
`main:TUNNEL-PROJECT-HISTORY.md`
