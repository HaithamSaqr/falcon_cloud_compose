# Falcon Cloud Compose

مثبّت نظام فالكون بالـ Docker Compose. أمر واحد يشغّل ستاك معزول لكل عميل
(API + واجهة Angular). كل شيء يُشتق من **اسم العميل**: أسماء الحاويات،
الشبكة، الساب دومين، ومجلد البيانات. كل عميل مجلد مستقل تحت
`/opt/<name>/` — لذلك ترقية الإيمدج **لا تفقد البيانات**، ويمكن رؤية كل
عميل بوضوح على السيرفر.

## التثبيت من الجيت هب (سطر واحد)

```bash
curl -fsSL https://raw.githubusercontent.com/HaithamSaqr/falcon_cloud_compose/main/run.sh \
  | bash -s -- install --name eskan --api-port 5001 --web-port 5021
```

أو بالكلونة:

```bash
git clone https://github.com/HaithamSaqr/falcon_cloud_compose.git
cd falcon_cloud_compose
./run.sh install --name eskan --api-port 5001 --web-port 5021
```

بدون تمرير القيم، يسأل تفاعليًا عن الاسم والبورتات.

## ما يُشتق من `--name eskan`

| العنصر            | القيمة                        |
|-------------------|-------------------------------|
| حاوية الـ API     | `eskanapi`                    |
| حاوية الويب       | `eskan`                       |
| الشبكة            | `eskanerp-net`                |
| ساب دومين API     | `eskanapi.falcon-v.com`       |
| ساب دومين الويب   | `eskan.falcon-v.com`          |
| مجلد البيانات     | `/opt/eskan/`                 |

`--domain` يغيّر النطاق (الافتراضي `falcon-v.com`).

## الترقية بدون فقد البيانات

```bash
./run.sh upgrade --name eskan     # pull أحدث إيمدج + إعادة إنشاء الحاوية
```

**لماذا البيانات آمنة:** كل البيانات على المضيف في bind-mounts:

```
/opt/eskan/
├── etc/         → /etc/falconerp
├── uploads/     → /app/wwwroot/uploads
└── app-data/    → /app/App_Data   (servers.xml + مفاتيح DataProtection)
```

الترقية تعيد إنشاء الحاوية من الإيمدج الجديد وتعيد ربط نفس المجلدات.
حتى `./run.sh down` لا يحذف البيانات (لا نستخدم `-v` أبدًا).

## التحديث التلقائي (watchtower مشترك)

```bash
./run.sh watchtower     # نسخة واحدة للمضيف كله على :8088
```

نسخة **واحدة** فقط تراقب كل الحاويات وتحدّثها ليلًا. لا نشغّل watchtower
لكل عميل (كان سيتعارض على البورت 8088). التثبيت يشغّلها تلقائيًا ما لم
تمرّر `--no-watchtower`.

## باقي الأوامر

```bash
./run.sh list                 # العملاء المثبّتون + حالة الحاويات
./run.sh logs --name eskan    # متابعة اللوجات
./run.sh down --name eskan    # إيقاف (البيانات تبقى)
```

المسار الأساسي `/opt` قابل للتغيير عبر `FALCON_BASE_DIR`.
