#!/usr/bin/env bash
# Поднимает почтовые серверы для проверок и ручной работы.
#
# Серверов три, и ни один не умеет всего. Mailpit принимает почту, отдаёт
# её по POP3 и показывает в веб-морде — по ней удобно смотреть, что именно
# ушло с узла. GreenMail отдаёт почту по IMAP, которого у Mailpit нет.
# smtp4dev требует входа и предлагает CRAM-MD5 и XOAUTH2, которых
# не предлагают первые два (сверено: Mailpit 1.21 и свежий — только
# PLAIN и LOGIN, GreenMail 2.1 — тоже).
#
# Настоящие серверы, а не двойники: двойник показывает, что мы правильно
# разговариваем сами с собой, а чужой сервер — что нас понимает кто-то
# ещё. Разница вылезает на первом же многострочном ответе.
#
#   test/stand/mail.sh          # поднять оба
#   test/stand/mail.sh stop     # погасить
#
# Веб-морда Mailpit: http://127.0.0.1:8025
set -euo pipefail

cd "$(dirname "$0")"

MAILPIT_IMAGE='axllent/mailpit:v1.21'
MAILPIT_CONTAINER='tnt-stand-mailpit'

GREENMAIL_IMAGE='greenmail/standalone:2.1.0'
GREENMAIL_CONTAINER='tnt-stand-greenmail'

SMTP4DEV_IMAGE='rnwood/smtp4dev:3.15.0'
SMTP4DEV_CONTAINER='tnt-stand-smtp4dev'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: почтовые серверы поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${MAILPIT_CONTAINER}" "${GREENMAIL_CONTAINER}" "${SMTP4DEV_CONTAINER}" > /dev/null 2>&1 || true
    echo 'Почтовые серверы остановлены'
    exit 0
fi

mkdir -p run

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Письма в нём — проверочные, жалеть их незачем.
docker rm -f "${MAILPIT_CONTAINER}" "${GREENMAIL_CONTAINER}" "${SMTP4DEV_CONTAINER}" > /dev/null 2>&1 || true

docker run -d \
    --name "${MAILPIT_CONTAINER}" \
    -p '127.0.0.1:1025:1025' \
    -p '127.0.0.1:8025:8025' \
    -p '127.0.0.1:1110:1110' \
    -e MP_POP3_AUTH='dev:dev' \
    "${MAILPIT_IMAGE}" > /dev/null

# Учётные записи GreenMail заводятся сами при первом входе: ящик под
# любым именем и паролем. Для проверок это ровно то, что нужно.
docker run -d \
    --name "${GREENMAIL_CONTAINER}" \
    -p '127.0.0.1:3025:3025' \
    -p '127.0.0.1:3143:3143' \
    -p '127.0.0.1:3110:3110' \
    -e GREENMAIL_OPTS='-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.auth.disabled' \
    "${GREENMAIL_IMAGE}" > /dev/null

# smtp4dev проверяет пароль по списку учётных записей, а не принимает
# любой: иначе неверный пароль по CRAM-MD5 проходил бы, и проверка отзыва
# ничего не проверяла бы. Токены XOAUTH2 он сверяет только с настоящим
# поставщиком OAuth 2.0 — здесь их отвергает, но команду разбирает.
docker run -d \
    --name "${SMTP4DEV_CONTAINER}" \
    -p '127.0.0.1:2025:25' \
    -p '127.0.0.1:2080:80' \
    -e ServerOptions__HostName='smtp4dev' \
    -e ServerOptions__TlsMode='None' \
    -e ServerOptions__AuthenticationRequired='true' \
    -e ServerOptions__SmtpAllowAnyCredentials='false' \
    -e ServerOptions__Users__0__Username='dev' \
    -e ServerOptions__Users__0__Password='dev' \
    -e ServerOptions__Users__0__DefaultMailbox='Default' \
    "${SMTP4DEV_IMAGE}" > /dev/null

echo "${MAILPIT_CONTAINER} ${GREENMAIL_CONTAINER} ${SMTP4DEV_CONTAINER}" > run/mail.containers

# Готовности ждём: проверки, запущенные сразу после подъёма, иначе
# пропустятся — и это выглядит как «всё хорошо», хотя ничего не проверено.
for _ in $(seq 1 60); do
    if curl -s -f -o /dev/null "http://127.0.0.1:8025/api/v1/info" \
        && nc -z 127.0.0.1 3143 > /dev/null 2>&1 \
        && curl -s -f -o /dev/null "http://127.0.0.1:2080/api/Messages"; then
        echo 'Почта поднята:'
        echo '  Mailpit   SMTP 1025, POP3 1110 (dev/dev), веб http://127.0.0.1:8025'
        echo '  GreenMail SMTP 3025, IMAP 3143, POP3 3110 (любые имя и пароль)'
        echo '  smtp4dev  SMTP 2025 (dev/dev; CRAM-MD5, PLAIN, LOGIN, XOAUTH2), веб http://127.0.0.1:2080'
        exit 0
    fi

    sleep 0.5
done

echo 'Почтовые серверы не ответили за 30 секунд: смотрите docker logs' >&2
exit 1
