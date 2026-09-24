rockspec_format = '3.0'

package = 'tnt-mail'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-mail.git',
    branch = 'main',
}

description = {
    summary = 'Почта для Tarantool: отправка по SMTP, чтение по POP3 и IMAP, TLS, вложения и чужие кодировки',
    detailed = [[
        Узлу нужна почта по двум поводам: сказать человеку, что случилось,
        и прочитать ответ. mail.send отправляет письмо по SMTP, mail.fetch
        забирает письма по POP3 насовсем либо смотрит их по IMAP, не отнимая
        у человека, который читает тот же ящик; у IMAP есть папки, поиск
        непрочитанного и флаги. mail.render собирает письмо, ничего
        не отправляя.

        Письмо собирается целиком: тема по RFC 2047, тело в base64
        строками по 76 знаков, текст с разметкой — multipart/alternative,
        вложения — multipart/mixed с именем по RFC 2231, дата по-английски
        независимо от локали, Message-ID всегда, точка в начале строки
        удваивается. Чужие письма разбираются терпеливо: перенесённые
        заголовки, base64 и quoted-printable, вложенные части; тема, текст
        и имя вложения переводятся в UTF-8 по объявленной кодировке —
        из Windows они приходят в cp1251, — а содержимое вложения остаётся
        байтами.

        Письма приложения — объявлениями mail.letters: тема, получатели,
        вид на tnt-template и данные; простой текст выводится из той же
        разметки. Отправка — сразу либо очередью с send (tnt-queue):
        письмо собирается при постановке и повторяется тем же Message-ID,
        отказ 4xx повторяется, 5xx зарывается сразу (mail.refusal).
        Предпросмотр кладёт письма в файлы для браузера — make
        mail-preview. Шаблоны и очередь приходят аргументами.

        Шифрование — с первого байта (465, 993, 995) либо STARTTLS.
        Пароль без TLS уходит открытым текстом, и вход с ним требует явного
        признания настройкой allow_plaintext_auth. Способ входа в SMTP
        выбирается из объявленных сервером: CRAM-MD5, PLAIN, LOGIN;
        XOAUTH2 — по токену OAuth 2.0 у SMTP, IMAP и POP3, и пароль тогда —
        функция-поставщик, которую почта зовёт перед каждым входом: токен
        живёт час. Срок назначен каждой операции, отказ — пара, а не
        исключение.

        Отправки видны рядами метрик: сколько писем ушло и сколько
        отказов каждого рода, и сколько шёл разговор с сервером.

        Зависит от tnt-must (отказ настройки и проверки аргументов),
        tnt-id (ULID для Message-ID), tnt-log (запись о неотправленном
        письме), tnt-str (перевод кодировок поверх iconv), tnt-tls (TLS
        поверх сокета), tnt-fs (файлы предпросмотра), tnt-metrics (ряды
        отправок), tnt-clock (длительность разговора) и tnt-external
        (подмена сети, шифрования, часов и вывода в проверках). Покрытие
        строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-mail',
    issues_url = 'https://github.com/tnt-skein/tnt-mail/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'mail', 'email', 'smtp', 'imap', 'pop3', 'mime' },
}

dependencies = {
    'lua >= 5.1',
    -- Отказ настройки словом, без места в коде.
    'tnt-must',
    -- Идентификатор письма — ULID.
    'tnt-id',
    -- Запись «письмо не отправлено» с причиной.
    'tnt-log',
    -- Подмена сети и шифрования в проверках.
    'tnt-external',
    -- Перекодировка чужих писем в UTF-8: `str.decode` поверх встроенного
    -- iconv, с отказом парой и без суффиксов `//IGNORE`, которые портят
    -- соседние конвертеры.
    'tnt-str',
    -- Шифрование с первого байта и STARTTLS.
    'tnt-tls',
    -- Файлы предпросмотра писем: подмена целиком и каталог с отказом парой.
    'tnt-fs',
    -- Ряды отправок в реестре встроенного metrics: итог и длительность.
    'tnt-metrics',
    -- Длительность разговора с сервером — монотонными часами.
    'tnt-clock',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.mail'] = 'tnt/mail.lua',
        ['tnt.mail.transport'] = 'tnt/mail/transport.lua',
        ['tnt.mail.encode'] = 'tnt/mail/encode.lua',
        ['tnt.mail.message'] = 'tnt/mail/message.lua',
        ['tnt.mail.parse'] = 'tnt/mail/parse.lua',
        ['tnt.mail.text'] = 'tnt/mail/text.lua',
        ['tnt.mail.refusal'] = 'tnt/mail/refusal.lua',
        ['tnt.mail.series'] = 'tnt/mail/series.lua',
        ['tnt.mail.preview'] = 'tnt/mail/preview.lua',
        ['tnt.mail.letters'] = 'tnt/mail/letters.lua',
        ['tnt.mail.smtp'] = 'tnt/mail/smtp.lua',
        ['tnt.mail.pop3'] = 'tnt/mail/pop3.lua',
        ['tnt.mail.imap'] = 'tnt/mail/imap.lua',
    },
}
