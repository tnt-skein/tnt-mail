--- Тесты разговора по IMAP: метки, литералы, папки, поиск, флаги.

local t = require('luatest')

local g = t.group('tnt.mail.imap')

local helper = dofile('test/helper.lua')

---@type any
local imap

--- Настройки ящика.
local WHERE = { username = 'dev@example.org', password = 'secret' }

g.before_each(function()
    imap = helper.load('tnt.mail.imap')
end)

g.after_each(function()
    helper.unload()
end)

--- Ведёт разговор с заранее написанными ответами сервера.
local take = helper.taker('tnt.mail.imap', WHERE)

--- Начало разговора: приветствие, вход, выбор папки, поиск.
---@param found string Что вернул поиск
---@return string[]
local function opening(found)
    return {
        '* OK IMAP4rev1 сервер готов',
        'a0001 OK вход выполнен',
        '* 2 EXISTS',
        'a0002 OK [READ-WRITE] папка выбрана',
        '* SEARCH ' .. found,
        'a0003 OK поиск закончен',
    }
end

g.test_letter_is_fetched_with_its_literal = function()
    -- Письмо приходит литералом: строка кончается длиной в скобках,
    -- а следом идёт ровно столько байт. Читать их построчно нельзя —
    -- внутри письма есть и переводы строк, и строки, похожие на ответы.
    local letters, err, said = take({
        '* OK сервер готов',
        'a0001 OK вход выполнен',
        '* 1 EXISTS',
        'a0002 OK папка выбрана',
        '* SEARCH 1',
        'a0003 OK поиск закончен',
        '* 1 FETCH (UID 42 BODY[] {42}',
        'Subject: тема\r\n\r\nтело письма',
        ')',
        'a0004 OK письмо отдано',
    }, { limit = 1 })

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 1)
    t.assert_equals(helper.at(letters, 1).id, '42')
    t.assert_str_contains(helper.at(letters, 1).raw, 'тело письма')
    t.assert_equals(said[1], 'a0001 LOGIN "dev@example.org" "secret"')
    t.assert_equals(said[2], 'a0002 SELECT "INBOX"')
    t.assert_equals(said[3], 'a0003 SEARCH ALL')
    t.assert_equals(said[4], 'a0004 FETCH 1 (UID BODY.PEEK[])')
end

g.test_letters_are_taken_newest_first = function()
    local answers = opening('1 2')

    for _, line in ipairs({
        '* 2 FETCH (UID 20 BODY[] {6}',
        'второе',
        ')',
        'a0004 OK отдано',
        '* 1 FETCH (UID 10 BODY[] {6}',
        'первое',
        ')',
        'a0005 OK отдано',
    }) do
        table.insert(answers, line)
    end

    local letters = take(answers, { limit = 2 })

    t.assert_equals(#letters, 2)
    t.assert_equals(helper.at(letters, 1).number, 2)
    t.assert_equals(helper.at(letters, 1).id, '20')
    t.assert_equals(helper.at(letters, 2).number, 1)
end

g.test_unseen_search_is_asked_when_requested = function()
    local _, _, said = take(opening(''), { unseen = true })

    t.assert_equals(said[3], 'a0003 SEARCH UNSEEN')
end

g.test_folder_is_chosen_by_request = function()
    local _, _, said = take({
        '* OK готов',
        'a0001 OK вход',
        'a0002 OK папка выбрана',
        '* SEARCH',
        'a0003 OK поиск',
    }, { folder = 'Архив' })

    t.assert_equals(said[2], 'a0002 SELECT "Архив"')
end

g.test_empty_folder_gives_nothing_and_no_error = function()
    local letters, err = take(opening(''))

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_letters_are_not_marked_seen_by_the_reading = function()
    -- BODY.PEEK[] вместо BODY[]: узел здесь наблюдатель, и признак
    -- непрочитанного письма принадлежит человеку.
    local answers = opening('1')

    for _, line in ipairs({ '* 1 FETCH (UID 7 BODY[] {4}', 'тело', ')', 'a0004 OK отдано' }) do
        table.insert(answers, line)
    end

    local _, _, said = take(answers)

    t.assert_str_contains(said[4], 'BODY.PEEK[]')

    for _, line in ipairs(said) do
        t.assert_equals(line:find('STORE', 1, true), nil, 'флаги не трогались')
    end
end

g.test_marking_seen_is_asked_when_requested = function()
    local answers = opening('1')

    for _, line in ipairs({
        '* 1 FETCH (UID 7 BODY[] {4}',
        'тело',
        ')',
        'a0004 OK отдано',
        'a0005 OK помечено',
    }) do
        table.insert(answers, line)
    end

    local _, _, said = take(answers, { mark_seen = true })

    t.assert_equals(said[5], 'a0005 STORE 1 +FLAGS (\\Seen)')
end

g.test_deletion_marks_and_expunges = function()
    -- Пометка без EXPUNGE переживает соединение и однажды удивит
    -- человека, который откроет ящик.
    local answers = opening('1')

    for _, line in ipairs({
        '* 1 FETCH (UID 7 BODY[] {4}',
        'тело',
        ')',
        'a0004 OK отдано',
        'a0005 OK помечено',
        'a0006 OK стёрто',
    }) do
        table.insert(answers, line)
    end

    local _, _, said = take(answers, { delete = true })

    t.assert_equals(said[5], 'a0005 STORE 1 +FLAGS (\\Deleted)')
    t.assert_equals(said[6], 'a0006 EXPUNGE')
end

g.test_wrong_password_is_reported = function()
    local letters, err = take({ '* OK готов', 'a0001 NO неверный пароль' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'вход')
    t.assert_str_contains(err, 'неверный пароль')
end

g.test_missing_folder_is_reported = function()
    local letters, err = take({
        '* OK готов',
        'a0001 OK вход',
        'a0002 NO нет такой папки',
    }, { folder = 'Черновики' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'Черновики')
end

g.test_refused_search_is_reported = function()
    local letters, err = take({
        '* OK готов',
        'a0001 OK вход',
        'a0002 OK папка выбрана',
        'a0003 BAD не понял команду',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'поиск')
end

g.test_refused_letter_names_its_number = function()
    local answers = opening('3')

    table.insert(answers, 'a0004 NO письма больше нет')

    local letters, err = take(answers)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'письмо 3')
end

g.test_silent_server_is_reported = function()
    local letters, err = take({})

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'приветствие')
end

g.test_torn_literal_is_reported = function()
    -- Сервер обещал столько байт и оборвал соединение: половина письма
    -- не письмо.
    local letters, err = take({
        '* OK готов',
        'a0001 OK вход',
        'a0002 OK папка',
        '* SEARCH 1',
        'a0003 OK поиск',
        '* 1 FETCH (UID 7 BODY[] {100}',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'письмо 1')
end

g.test_folders_are_listed = function()
    -- Список папок ходит своим соединением: он нужен и до того,
    -- как выбрана папка, — поэтому подменяется сокет, а не разговор.
    local folders, err = helper.through({
        '* OK готов',
        'a0001 OK вход',
        '* LIST (\\HasNoChildren) "/" "INBOX"',
        '* LIST (\\HasNoChildren) "/" "Архив"',
        'a0002 OK список готов',
        'a0003 OK до свидания',
    }, function()
        return imap.folders(WHERE)
    end)

    t.assert_equals(err, nil)
    t.assert_equals(folders, { 'INBOX', 'Архив' })
end

g.test_broken_link_stops_the_conversation = function()
    local letters, err = imap.take(helper.broken_link('* OK готов'), WHERE, {})

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'сеть пропала')
end

g.test_torn_answer_is_reported = function()
    -- Сервер оборвал соединение посреди ответа: читать дальше нечего.
    local letters, err = take({ '* OK готов' })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'вход')
end

g.test_missing_server_is_reported_by_fetch = function()
    local letters, err = helper.through(nil, function()
        return imap.fetch({ host = 'ящик', port = 143 }, {})
    end)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'ящик')
end

g.test_missing_server_is_reported_by_folders = function()
    local folders, err = helper.through(nil, function()
        return imap.folders({ host = 'ящик', port = 143 })
    end)

    t.assert_equals(folders, nil)
    t.assert_str_contains(err, 'ящик')
end

g.test_folders_need_a_login_first = function()
    local folders, err = helper.through({ '* OK готов', 'a0001 NO неверный пароль' }, function()
        return imap.folders(WHERE)
    end)

    t.assert_equals(folders, nil)
    t.assert_str_contains(err, 'вход')
end

g.test_refused_list_of_folders_is_reported = function()
    local folders, err = helper.through({
        '* OK готов',
        'a0001 OK вход',
        'a0002 NO не показываю папки',
        'a0003 OK до свидания',
    }, function()
        return imap.folders(WHERE)
    end)

    t.assert_equals(folders, nil)
    t.assert_str_contains(err, 'список папок')
end

g.test_folder_name_without_quotes_is_listed = function()
    -- Кавычки сервер ставит не всегда: имя без пробелов он присылает
    -- голым словом, и папкой оно от этого быть не перестаёт.
    local folders = helper.through({
        '* OK готов',
        'a0001 OK вход',
        '* LIST (\\HasNoChildren) "/" Архив',
        '* LIST (\\HasNoChildren) "/" "Мои письма"',
        'a0002 OK список готов',
        'a0003 OK до свидания',
    }, function()
        return imap.folders(WHERE)
    end)

    t.assert_equals(folders, { 'Архив', 'Мои письма' })
end

g.test_lines_that_only_look_like_folders_are_skipped = function()
    -- Разбор строгий нарочно: строка, похожая на список папок, но
    -- собранная не так, — это чужой ответ, а не папка с кривым именем.
    local folders = helper.through({
        '* OK готов',
        'a0001 OK вход',
        '*LIST (\\X) "/" "Без пробела после звёздочки"',
        '* LIST(\\X) "/" "Без пробела перед флагами"',
        '* LIST (\\X)"/" "Без пробела после флагов"',
        '* LIST (\\X)  "Ящик"',
        '* LIST (\\X) "/" ',
        '* LIST (\\X) "/" "Настоящая"',
        'a0002 OK список готов',
        'a0003 OK до свидания',
    }, function()
        return imap.folders(WHERE)
    end)

    t.assert_equals(folders, { 'Настоящая' })
end

--- Разговор с пустым ящиком: остаётся выбрать, что ответит поиск.
---@param search string Строка ответа на поиск
---@return string[]
local function empty_mailbox(search)
    return {
        '* OK готов',
        'a0001 OK вход',
        '* 0 EXISTS',
        'a0002 OK папка',
        search,
        'a0003 OK поиск',
    }
end

g.test_search_without_numbers_gives_no_letters = function()
    -- Пустой ящик: поиск отвечает строкой без единого номера.
    local letters, err = take(empty_mailbox('* SEARCH'))

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_search_line_without_a_space_is_not_a_search = function()
    -- `*SEARCH` без пробела — не ответ поиска: принимать такое значит
    -- читать письма по номерам, которых сервер не называл.
    local letters, err = take(empty_mailbox('*SEARCH 1'))

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_empty_literal_length_is_not_a_literal = function()
    -- Литерал без длины: сервер оборвал строку на полуслове. Читать
    -- следом ноль байт нельзя — это разъедет весь дальнейший разговор.
    local letters, err = take({
        '* OK готов',
        'a0001 OK вход',
        '* 1 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1',
        'a0003 OK поиск',
        '* 1 FETCH (UID 7 BODY[] {}',
        'a0004 OK письмо',
    })

    t.assert_equals(err, nil)
    t.assert_equals(helper.at(letters, 1).raw, '')
end

g.test_identifier_needs_a_space_after_uid = function()
    -- `UID7` — не опознаватель: семёрка здесь часть слова, и письмо
    -- лучше отдать без устойчивого имени, чем с выдуманным.
    local letters = take({
        '* OK готов',
        'a0001 OK вход',
        '* 1 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1',
        'a0003 OK поиск',
        '* 1 FETCH (UID7 BODY[] {6}',
        'письмо',
        'a0004 OK письмо',
    })

    t.assert_equals(helper.at(letters, 1).id, nil)
end

g.test_ten_letters_are_taken_when_no_limit_is_asked = function()
    -- Предел по умолчанию: ящик, в который не заглядывали месяц,
    -- иначе приедет на узел целиком.
    local answers = {
        '* OK готов',
        'a0001 OK вход',
        '* 12 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1 2 3 4 5 6 7 8 9 10 11 12',
        'a0003 OK поиск',
    }

    for number = 1, 12 do
        table.insert(answers, ('* %d FETCH (UID %d BODY[] {6}'):format(number, number))
        table.insert(answers, 'письмо')
        table.insert(answers, ('a%04d OK письмо'):format(number + 3))
    end

    local letters, err = take(answers)

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 10)
    t.assert_equals(helper.at(letters, 1).number, 12)
    t.assert_equals(helper.at(letters, 10).number, 3)
end

g.test_limit_takes_exactly_the_newest_letters = function()
    -- Предел считается от конца: два письма — это два последних,
    -- а не два первых и не три.
    local letters, err = take({
        '* OK готов',
        'a0001 OK вход',
        '* 5 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1 2 3 4 5',
        'a0003 OK поиск',
        '* 5 FETCH (UID 55 BODY[] {8}',
        'пятое',
        'a0004 OK письмо',
        '* 4 FETCH (UID 44 BODY[] {10}',
        'четвёртое',
        'a0005 OK письмо',
    }, { limit = 2 })

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 2)
    t.assert_equals(helper.at(letters, 1).number, 5)
    t.assert_equals(helper.at(letters, 2).number, 4)
end

g.test_state_written_in_lower_case_is_not_an_answer = function()
    -- Состояние ответа сервер пишет прописными. Строчное слово с нашей
    -- меткой — чужая строка, похожая на ответ, и разговор обязан
    -- дождаться настоящего.
    local answers = empty_mailbox('* SEARCH')

    table.insert(answers, 2, 'a0001 ok это не ответ')

    local letters, err = take(answers)

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_search_glued_to_a_number_is_not_a_search = function()
    -- `* SEARCH12` — слово, слипшееся с числом: номеров писем здесь нет.
    local letters, err = take(empty_mailbox('* SEARCH12 13'))

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
end

g.test_only_words_of_digits_are_letter_numbers = function()
    -- CONDSTORE дописывает к ответу `(MODSEQ …)`, а сервер со странностями —
    -- что угодно: номер письма — только слово из одних цифр. Иначе письма
    -- читались бы по номерам, которых сервер не называл: `917162500)`,
    -- `0x10` или `inf`.
    local letters, err, said = take({
        '* OK готов',
        'a0001 OK вход',
        '* 4 EXISTS',
        'a0002 OK папка',
        '* SEARCH 2 4 0x10 inf (MODSEQ 917162500)',
        'a0003 OK поиск',
        '* 4 FETCH (UID 44 BODY[] {6}',
        'письмо',
        'a0004 OK письмо',
        '* 2 FETCH (UID 22 BODY[] {6}',
        'письмо',
        'a0005 OK письмо',
    })

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 2)
    t.assert_equals(helper.at(letters, 1).number, 4)
    t.assert_equals(helper.at(letters, 2).number, 2)
    t.assert_equals(said[4], 'a0004 FETCH 4 (UID BODY.PEEK[])')
    t.assert_equals(said[5], 'a0005 FETCH 2 (UID BODY.PEEK[])')
end

g.test_uid_without_a_number_gives_no_identifier = function()
    -- Слово UID без числа: опознавателя у письма нет, и придумывать
    -- пустой — значит однажды сравнить два письма по пустоте.
    local letters = take({
        '* OK готов',
        'a0001 OK вход',
        '* 1 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1',
        'a0003 OK поиск',
        '* 1 FETCH (UID BODY[] {6}',
        'письмо',
        'a0004 OK письмо',
    })

    t.assert_equals(helper.at(letters, 1).id, nil)
end

--- Разговор с переходом на шифрование: вход идёт уже под ним.
local take_with_tls = helper.tls_taker('tnt.mail.imap', {
    username = 'dev@example.org',
    password = 'secret',
    tls = 'starttls',
}, 'рукопожатие TLS не удалось: имя узла не совпало')

g.test_login_waits_for_encryption = function()
    -- Имя и пароль идут в LOGIN одной строкой: открытым текстом они
    -- отдаются целиком, поэтому переход делается до входа.
    local letters, err, said, secret = take_with_tls({
        '* OK IMAP4rev1 сервер готов',
        'a0001 OK переходим на шифрование',
    }, {
        'a0002 OK вход выполнен',
        '* 0 EXISTS',
        'a0003 OK папка выбрана',
        '* SEARCH',
        'a0004 OK поиск закончен',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
    t.assert_equals(
        said,
        { 'a0001 STARTTLS' },
        'открытым текстом — только просьба о переходе'
    )
    t.assert_str_contains(helper.at(secret, 1), 'a0002 LOGIN')
    t.assert_str_contains(helper.at(secret, 1), 'dev@example.org')
end

g.test_refused_starttls_stops_before_the_login = function()
    local letters, err, said = take_with_tls({
        '* OK сервер готов',
        'a0001 NO шифрование не настроено',
    })

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'переход на шифрование')
    t.assert_equals(said, { 'a0001 STARTTLS' }, 'пароль не сказан вовсе')
end

g.test_failed_handshake_stops_before_the_login = function()
    local letters, err = take_with_tls({
        '* OK сервер готов',
        'a0001 OK переходим на шифрование',
    }, nil)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'имя узла не совпало')
end

g.test_fetch_says_goodbye_before_closing = function()
    -- Прощание не формальность: сервер, не услышавший LOGOUT, считает
    -- соединение оборванным и пишет об этом в свой журнал на каждом такте
    -- уведомителя.
    local said

    local letters, err = helper.through({
        '* OK готов',
        'a0001 OK вход',
        '* 1 EXISTS',
        'a0002 OK папка',
        '* SEARCH 1',
        'a0003 OK поиск',
        '* 1 FETCH (UID 7 BODY[] {6}',
        'письмо',
        'a0004 OK письмо',
        'a0005 OK до свидания',
    }, function()
        local fetched, fetch_error = imap.fetch({
            host = 'ящик',
            port = 143,
            username = 'dev@example.org',
            password = 'secret',
        }, { limit = 1 })

        said = helper.module('tnt.mail.transport')

        return fetched, fetch_error
    end)

    t.assert_equals(err, nil)
    t.assert_equals(#letters, 1)
    t.assert_equals(helper.at(letters, 1).id, '7')
    t.assert_not_equals(said, nil)
end

--- Приветствие и согласие на переход: открытым текстом больше ничего.
local BEFORE_TLS = { '* OK IMAP4rev1 сервер готов', 'a0001 OK переходим на шифрование' }

--- Ящик, в который входят после перехода на шифрование.
local SECURED = {
    host = 'ящик',
    port = 143,
    username = 'dev@example.org',
    password = 'secret',
    tls = 'starttls',
}

g.test_quote_and_backslash_are_escaped = function()
    -- Имя, пароль и папка идут в кавычках, и кавычка внутри них обрывала
    -- бы строку: сервер прочёл бы остаток пароля новыми словами команды
    -- и отказал во входе с верным паролем. Обратная косая экранирует
    -- и кавычку, и саму себя (RFC 3501, quoted).
    local _, _, said = helper.taker('tnt.mail.imap', {
        username = 'dev"ops',
        password = [[pa\ss"word]],
    })(
        { '* OK готов', 'a0001 OK вход', 'a0002 NO папки нет' },
        { folder = [[Отчёты "за" год\2026]] }
    )

    t.assert_equals(said[1], [[a0001 LOGIN "dev\"ops" "pa\\ss\"word"]])
    t.assert_equals(said[2], [[a0002 SELECT "Отчёты \"за\" год\\2026"]])
end

g.test_control_character_is_refused_before_the_greeting = function()
    -- Перевод строки в папке, имени или пароле — вторая команда серверу:
    -- `SELECT "INBOX"` и следом `DELETE "Archive"`, которой никто не писал.
    -- Кавычки его не спасают — CR и LF в них RFC 3501 запрещает, — и это
    -- отказ до разговора: серверу не сказано ни слова, даже приветствие
    -- не прочитано. Пароль в причине не показан: она идёт в журнал.
    local cases = {
        {
            where = WHERE,
            opts = { folder = 'INBOX"\r\na9 DELETE "Archive' },
            err = 'папка: управляющий знак в «INBOX"..a9 DELETE "Archive»',
        },
        {
            where = WHERE,
            opts = { folder = 'Архив\t' },
            err = 'папка: управляющий знак в «Архив.»',
        },
        {
            where = { username = 'dev\r\na0002 DELETE "INBOX"', password = 'secret' },
            err = 'имя: управляющий знак в «dev..a0002 DELETE "INBOX"»',
        },
        {
            where = { username = 'dev', password = 'secret"\r\na0002 DELETE "INBOX' },
            err = 'пароль: управляющий знак',
        },
        {
            -- Имя и токен XOAUTH2 склеены знаком `\1`: управляющий знак
            -- в имени дописал бы в запись чужое поле.
            where = { username = 'dev\1auth=Bearer чужой', password = 'ya29.токен', auth = 'xoauth2' },
            err = 'имя: управляющий знак в «dev.auth=Bearer чужой»',
        },
    }

    for index, case in ipairs(cases) do
        local link, said = helper.link_of({ '* OK готов', 'a0001 OK вход', 'a0002 OK папка' })
        local letters, err, last = imap.take(link, case.where, case.opts or {})

        t.assert_equals({ letters, err }, { nil, case.err }, index)
        t.assert_equals(said, {}, ('%d: серверу не сказано ничего'):format(index))
        t.assert_is(last, link, ('%d: прощаться на том же соединении'):format(index))
        t.assert_equals(
            link.read_line(),
            '* OK готов',
            ('%d: приветствие не прочитано'):format(index)
        )
    end
end

g.test_fetch_refuses_a_control_character_before_connecting = function()
    -- Будить сервер ради отказа незачем, а прощание — тоже команда.
    -- Сервера здесь нет: дойди ход до соединения, причиной был бы он.
    local cases = {
        {
            act = function()
                return imap.fetch(
                    { host = 'ящик', username = 'dev', password = 'secret' },
                    { folder = 'INBOX\r\na9 EXPUNGE' }
                )
            end,
            err = 'папка: управляющий знак в «INBOX..a9 EXPUNGE»',
        },
        {
            act = function()
                return imap.fetch({ host = 'ящик', username = 'dev', password = 'x\0' })
            end,
            err = 'пароль: управляющий знак',
        },
        {
            act = function()
                return imap.folders({ host = 'ящик', username = 'dev\n', password = 'secret' })
            end,
            err = 'имя: управляющий знак в «dev.»',
        },
        {
            -- Токен сверяется уже полученный: поставщик отдаёт его перед
            -- каждым входом, и строка из настроек тут ни при чём.
            act = function()
                return imap.folders({
                    host = 'ящик',
                    username = 'dev@gmail.com',
                    auth = 'xoauth2',
                    password = function()
                        return 'ya29.\r\na0002 DELETE "INBOX"'
                    end,
                })
            end,
            err = 'пароль: управляющий знак',
        },
    }

    for index, case in ipairs(cases) do
        t.assert_equals({ helper.through(nil, case.act) }, { nil, case.err }, index)
    end
end

g.test_goodbye_goes_under_encryption = function()
    -- После STARTTLS прежнее соединение негодно: LOGOUT, сказанный в него,
    -- уходит мимо шифрования, а незакрытое защищённое держит SSL и SSL_CTX,
    -- которых не видит ни один счётчик Lua. Так в любом исходе — и когда
    -- письма прочитаны, и когда разговор оборвался уже под шифрованием.
    local cases = {
        {
            name = 'письмо прочитано',
            after = {
                'a0002 OK вход',
                '* 1 EXISTS',
                'a0003 OK папка',
                '* SEARCH 1',
                'a0004 OK поиск',
                '* 1 FETCH (UID 7 BODY[] {6}',
                'письмо',
                'a0005 OK письмо',
                'a0001 OK до свидания',
            },
        },
        {
            name = 'вход отвергнут',
            after = { 'a0002 NO неверный пароль' },
            err = 'вход',
        },
        {
            name = 'папки нет',
            after = { 'a0002 OK вход', 'a0003 NO нет такой папки' },
            err = 'папка INBOX',
        },
        {
            name = 'поиск отвергнут',
            after = { 'a0002 OK вход', 'a0003 OK папка', 'a0004 BAD поиск не понят' },
            err = 'поиск',
        },
        {
            name = 'письмо не отдано',
            after = {
                'a0002 OK вход',
                'a0003 OK папка',
                '* SEARCH 1',
                'a0004 OK поиск',
                'a0005 NO письма нет',
            },
            err = 'письмо 1',
        },
    }

    for _, case in ipairs(cases) do
        local letters, err, said, secret = helper.through_tls(BEFORE_TLS, case.after, function()
            return imap.fetch(SECURED, { limit = 1 })
        end)

        helper.ended_under_tls(
            case,
            { letters = letters, err = err, said = said, secret = secret },
            { 'a0001 STARTTLS' },
            'a0001 LOGOUT'
        )
    end
end

g.test_refused_starttls_says_goodbye_in_the_open = function()
    -- Сервер отказал в переходе: разговор так и остался открытым,
    -- и прощаться, и закрывать надо его.
    local letters, err, said, secret = helper.through_tls({
        '* OK IMAP4rev1 сервер готов',
        'a0001 NO шифрование не настроено',
    }, {}, function()
        return imap.fetch(SECURED)
    end)

    t.assert_equals(letters, nil)
    t.assert_str_contains(err, 'переход на шифрование')
    t.assert_equals(said[#said], 'a0001 LOGOUT')
    t.assert_equals(said.closed, true)
    t.assert_equals(secret, {}, 'под шифрованием не сказано ничего')
end

g.test_folders_close_the_encrypted_link = function()
    -- Список папок ходит своим соединением, и после STARTTLS закрывать
    -- надо защищённое — и когда список получен, и когда вход отвергнут.
    local cases = {
        {
            name = 'список получен',
            after = { 'a0002 OK вход', '* LIST (\\HasNoChildren) "/" "INBOX"', 'a0003 OK список готов' },
            found = { 'INBOX' },
        },
        {
            name = 'вход отвергнут',
            after = { 'a0002 NO неверный пароль' },
            err = 'вход',
        },
    }

    for _, case in ipairs(cases) do
        local folders, err, said, secret = helper.through_tls(BEFORE_TLS, case.after, function()
            return imap.folders(SECURED)
        end)

        t.assert_equals(folders, case.found, case.name)

        if case.err == nil then
            t.assert_equals(err, nil, case.name)
        else
            t.assert_str_contains(err, case.err, false, case.name)
        end

        t.assert_equals(said, { 'a0001 STARTTLS' }, case.name .. ': открытый сокет не трогали')
        t.assert_equals(secret.closed, true, case.name .. ': защищённое соединение закрыто')
    end
end

-- ── XOAUTH2 ──────────────────────────────────────────────────────────

--- Ящик Gmail: вход по токену OAuth 2.0.
local OAUTH = { username = 'dev@gmail.com', password = 'ya29.токен', auth = 'xoauth2' }

--- Разговор со входом XOAUTH2.
local take_oauth = helper.taker('tnt.mail.imap', OAUTH)

--- Начальный ответ XOAUTH2, каким он уходит серверу.
local RECORD = require('digest').base64_encode('user=dev@gmail.com\1auth=Bearer ya29.токен\1\1', { nowrap = true })

g.test_xoauth2_sends_the_record_after_the_continuation = function()
    -- Начальный ответ — строкой после продолжения, а не в команде: так
    -- его понимает и сервер без SASL-IR.
    local letters, err, said = take_oauth({
        '* OK Gimap ready',
        '+ ',
        '* CAPABILITY IMAP4rev1 UNSELECT IDLE',
        'a0001 OK dev@gmail.com authenticated (Success)',
        'a0002 OK [READ-WRITE] INBOX selected',
        '* SEARCH',
        'a0003 OK SEARCH completed',
    })

    t.assert_equals(err, nil)
    t.assert_equals(letters, {})
    t.assert_equals({ said[1], said[2], said[3] }, { 'a0001 AUTHENTICATE XOAUTH2', RECORD, 'a0002 SELECT "INBOX"' })
end

g.test_xoauth2_refusal_is_finished_and_explained = function()
    local reason = '{"status":"401","schemes":"bearer","scope":"https://mail.google.com/"}'
    local letters, err, said = take_oauth({
        '* OK Gimap ready',
        '+',
        '+ ' .. require('digest').base64_encode(reason, { nowrap = true }),
        'a0001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)',
    })

    t.assert_equals(letters, nil)
    t.assert_equals(
        err,
        ('вход: a0001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure); причина: %s'):format(reason)
    )
    t.assert_equals(said[3], '', 'пустая строка завершает отказ')
end

g.test_xoauth2_not_offered_is_reported_at_once = function()
    -- Сервер без XOAUTH2 отвечает на команду сразу меткой: токен ему
    -- не отдаётся, и разговор не ждёт продолжения до срока.
    local letters, err, said = take_oauth({
        '* OK IMAP4rev1 Server GreenMail ready',
        "a0001 NO AUTHENTICATE failed. Unsupported authentication mechanism 'XOAUTH2'",
    })

    t.assert_equals(letters, nil)
    t.assert_equals(err, "вход: a0001 NO AUTHENTICATE failed. Unsupported authentication mechanism 'XOAUTH2'")
    t.assert_equals(said, { 'a0001 AUTHENTICATE XOAUTH2' })
end

g.test_xoauth2_over_a_broken_link_is_reported = function()
    local link = helper.broken_link('* OK сервер готов')
    local letters, err = helper.module('tnt.mail.imap').take(link, OAUTH, {})

    t.assert_equals(letters, nil)
    t.assert_equals(err, 'вход: сеть пропала')
end

g.test_a_continuation_on_an_ordinary_command_does_not_hang = function()
    -- Продолжения на обычную команду не бывает, но сервер, приславший его,
    -- получает отказ сразу, а не молчание до срока.
    local letters, err = take({ '* OK сервер готов', '+ ждём литерал' })

    t.assert_equals(letters, nil)
    t.assert_equals(err, 'вход: + ждём литерал')
end

g.test_folders_take_the_token_from_the_provider = function()
    local folders, err = helper.through({
        '* OK Gimap ready',
        '+ ',
        'a0001 OK authenticated',
        '* LIST (\\HasNoChildren) "/" "INBOX"',
        'a0002 OK LIST completed',
        'a0003 OK LOGOUT completed',
    }, function()
        return imap.folders({
            host = 'imap.gmail.com',
            username = 'dev@gmail.com',
            auth = 'xoauth2',
            password = function()
                return 'ya29.токен'
            end,
        })
    end)

    t.assert_equals({ folders, err }, { { 'INBOX' }, nil })
end

g.test_folders_without_a_token_do_not_connect = function()
    local folders, err = helper.through(nil, function()
        return imap.folders({
            host = 'imap.gmail.com',
            username = 'dev@gmail.com',
            auth = 'xoauth2',
            password = function()
                return nil, 'токен обновления отозван'
            end,
        })
    end)

    t.assert_equals(
        { folders, err },
        { nil, 'пароль не получен: токен обновления отозван' }
    )
end
