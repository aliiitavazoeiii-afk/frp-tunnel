# New Chat Continuation Prompt — AnyTLS / Bucket5

Copy/paste the prompt below into a fresh ChatGPT chat.

---

من می‌خوام پروژه AnyTLS/Bucket5 قبلی‌ام را دقیقاً از state فعلی ادامه بدیم.

Repo:
`aliiitavazoeiii-afk/frp-tunnel`

Branch:
`bucket5-v2`

قبل از هر تحلیل یا تغییر:

1. با GitHub connector خودت branch فعلی را بررسی کن و **اول فایل `ANYTLS-PROJECT-HISTORY.md` را کامل بخوان**. این فایل history/continuation اصلی پروژه تا پایان چت قبلی است.
2. بعد HEAD فعلی branch، `VERSION` و فایل‌های فعلی زیر را از GitHub دوباره fetch کن؛ چیزی را از حافظه حدس نزن:
   - `bucket5-render.py`
   - `bucket5-xui.py`
   - `bucket5-scheduler.py`
   - `bucket5-probe.sh`
   - `bucket5-diagnose-node.sh`
   - `bucket5-runtime-patch.py`
   - `install-bucket5-fresh.sh`
   - `install-bucket5-resume.sh`
   - `install-bucket5.sh`
3. `BUCKET5-RUNBOOK.md` را به‌تنهایی source of truth ندان؛ در topology/ports بخش‌هایی از آن stale است. current wrapper/runtime code و live state اولویت دارند.
4. production user فعال داریم. x-ui UUIDها، public inbound، user→bucket mapping و کاربران نباید تغییر یا regenerate شوند.
5. هیچ password، controller secret یا XUDP UUID را از من نخواه که paste کنم و هیچ secretی داخل repo نگذار. در صورت نیاز hash compare کن.
6. برای production change اول backup/candidate/full probe/rollback طراحی کن. مستقیم installer یا restartهای غیرضروری نزن.
7. base `install-bucket5.sh` را مستقیم روی production اجرا نکن مگر اینکه بعد از بررسی current code عمداً اصلاحش کرده باشیم؛ در state قبلی fresh/resume wrapperها runtime patch اعمال می‌کردند.

Current architecture در history کامل آمده: دو Iran gateway (`maya1`, `maya3`)، پنج Foreign logical node، ده stable bucket روی هر Maya، XUDP bucket ports `18101..18110` و Mihomo bucket carrier ports `7901..7910`.

نکته‌ی مهم current-state: در چت قبلی replacement F4 روی اولین Maya با موفقیت نصب و healthy شد، ولی **ثبت قطعی نداریم که maya3 هم به replacement F4 منتقل شده باشد**. قبل از هر change این موضوع را با live status/env بدون نمایش secret verify کن.

آخرین مسئله‌ی مهمی که بررسی کردیم F4 قدیمی `194.77.69.60` بود. dual-ended tcpdump نشان داد hard IP block نبود: TCP/TLS ابتدا کار می‌کرد، بعد بعضی payloadهای Maya→F4 بعد از خروج از NIC مایا به NIC F4 نمی‌رسیدند، در حالی که reverse traffic/ACKها هنوز می‌توانستند رد شوند. load بالا هم با داده‌ها علت قانع‌کننده‌ای نبود. old F4 intermittent بود: یک full probe PASS و چند دقیقه بعد FAIL. نتیجه‌ی دقیق و confidenceها داخل history ثبت شده؛ آن را بخوان و از آن بیشتر از evidence نتیجه نگیر.

### چیزی که الان می‌خواهم ادامه دهیم

می‌خواهم نسل بعدی Bucket5 را برای **transport-aware failover** طراحی کنیم، ترجیحاً اول روی F4/canary:

- logical F4 برای bucketها همان F4 بماند.
- زیر F4 حداقل دو carrier از قبل آماده باشند، مثلاً ResTLS و ShadowTLS روی listenerهای مستقل.
- اگر carrier فعال fail شد، scheduler ابتدا carrier دوم را isolated probe کند؛ اگر PASS شد فقط transport داخلی F4 عوض شود و F4 از pool خارج نشود.
- فقط اگر همه transportهای F4 fail شدند، existing Bucket5 node failover اجرا شود و bucketها به F1/F2/F3/F5 بروند.
- user→bucket mapping و x-ui هیچ تغییری نکند.
- switch باید health-aware، drain-controlled و anti-flap/hysteresis داشته باشد.
- بعد از اثبات این مدل، health-aware randomized transport hopping را بررسی کنیم (مثلاً dwell تصادفی به‌جای fixed 6h)، اما availability همیشه مقدم باشد و destination transport قبل از switch probe شود.
- اگر transport rotation اضافه شد، nodeها stagger شوند تا reconnect storm نداشته باشیم.

اول repo و history را کامل بررسی کن، بعد current live state لازم را با **حداقل commandهای read-only دقیق** از من بگیر. سپس design را کامل ببند و اگر نیاز به تغییر repo است، exact current SHAها را fetch کن و patch امن بده. من commandهای terminal-ready و بدون حدس می‌خواهم.

---

The detailed historical source for this prompt is `ANYTLS-PROJECT-HISTORY.md` on branch `bucket5-v2`.
