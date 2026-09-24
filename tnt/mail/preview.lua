--- Предпросмотр писем: готовое письмо в файлах, без отправки.
---
--- Посмотреть письмо иначе можно только отправив его — на живой ящик
--- или в приёмник проверок. Предпросмотр собирает письмо так же, как
--- отправка, и кладёт его в каталог тремя файлами:
---
--- | Файл | Что | Чем смотреть |
--- |---|---|---|
--- | `<имя>.html` | часть с разметкой, байт в байт | браузером |
--- | `<имя>.txt` | простой текст | браузером либо редактором |
--- | `<имя>.eml` | письмо целиком, как уйдёт серверу | почтовой программой |
---
--- и `index.html` — оглавление: письма с темой и получателями в том виде,
--- в каком их покажет почтовая программа, и ссылки на файлы.
---
--- Разметка и текст начинаются меткой порядка байтов UTF-8. Кодировку
--- части в письме называет её заголовок, а у файла заголовков нет:
--- по метке браузер читает кириллицу как UTF-8, даже если рамка письма
--- не объявила `<meta charset>`. Сама разметка после метки — та же, что
--- уходит получателю.
---
--- Вход для цели сборки — `main`: `make mail-preview LETTERS=app.mail`,
--- где `app.mail` — модуль, отдающий письма (`mail.letters`).

local utf8 = require('utf8')

local external = require('tnt.external')
local fs = require('tnt.fs')

local parse = require('tnt.mail.parse')

local Module = {}

--- Вывод цели сборки — внешняя зависимость: проверки читают его, не трогая
--- настоящие потоки процесса.
local source = external.install(Module, {
    say = function(line)
        io.stdout:write(line, '\n')
    end,
    complain = function(line)
        io.stderr:write(line, '\n')
    end,
})

--- Метка порядка байтов: по ней браузер читает файл как UTF-8.
local BOM = utf8.char(0xFEFF)

--- Каталог по умолчанию у цели сборки.
Module.DIRECTORY = 'var/mail-preview'

--- Чем заменяется каждый из пяти знаков, которых боится HTML.
local ESCAPED = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&#39;' }

--- Экранирует значение для оглавления.
---
--- Образец ловит любой знак препинания, а что экранировать, решает одна
--- таблица: знак, которого в ней нет, остаётся собой.
---@param value any
---@return string
local function escaped(value)
    return (tostring(value or ''):gsub('%p', ESCAPED))
end

--- Имя файла письма: имя объявления без знаков, которые значат путь.
---@param name string
---@return string
local function file_of(name)
    return (name:gsub('[^%w%.%-_]', '_'))
end

--- Кладёт файл; отказ — текстом.
---@param path string
---@param content string
---@return string|nil err
local function put(path, content)
    local written, err = fs.replace(path, content)

    if not written then
        return tostring(err)
    end

    return nil
end

--- Части письма в оглавлении: поле записи, расширение файла и подпись.
local PARTS = {
    { field = 'html', extension = 'html', label = 'разметка' },
    { field = 'text', extension = 'txt', label = 'текст' },
    { field = 'eml', extension = 'eml', label = 'письмо' },
}

--- Оглавление: объявление страницы, её голова, шапка таблицы и конец.
local INDEX_DOCTYPE = '<!DOCTYPE html>'
local INDEX_PAGE = '<html lang="ru"><head><meta charset="utf-8"><title>Письма</title></head><body>'
local INDEX_HEADER = '<table><tr><th>Письмо</th><th>Тема</th><th>Кому</th><th>Файлы</th></tr>'
local INDEX_TAIL = '</table></body></html>'

--- Строка оглавления. Ссылки — на файлы рядом с оглавлением, по имени.
---@param entry TntMailPreviewEntry
---@return string
local function row(entry)
    local links = {}

    for _, part in ipairs(PARTS) do
        if entry[part.field] ~= nil then
            local file = ('%s.%s'):format(file_of(entry.name), part.extension)

            table.insert(links, ('<a href="%s">%s</a>'):format(escaped(file), part.label))
        end
    end

    return ('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>'):format(
        escaped(entry.name),
        escaped(entry.subject),
        escaped(entry.to),
        table.concat(links, ' ')
    )
end

--- Оглавление каталога предпросмотра.
---@param entries TntMailPreviewEntry[]
---@return string
local function index_of(entries)
    local rows = {}

    for _, entry in ipairs(entries) do
        table.insert(rows, row(entry))
    end

    local lines = { INDEX_DOCTYPE, INDEX_PAGE, INDEX_HEADER, table.concat(rows, '\n'), INDEX_TAIL, '' }

    return table.concat(lines, '\n')
end

--- Письмо в каталоге предпросмотра.
---@class TntMailPreviewEntry
---@field name string Имя объявления
---@field subject string|nil Тема, как её покажет почтовая программа
---@field to string|nil Получатели, как их покажет почтовая программа
---@field html string|nil Путь к разметке; у письма без разметки его нет
---@field text string Путь к простому тексту
---@field eml string Путь к письму целиком

--- Каталог предпросмотра: оглавление и письма.
---@class TntMailPreview
---@field index string Путь к оглавлению
---@field letters TntMailPreviewEntry[]

--- Кладёт одно письмо: разметку, текст и письмо целиком.
---@param directory string
---@param built { name: string, letter: table, raw: string }
---@return TntMailPreviewEntry|nil entry
---@return string|nil err
local function written(directory, built)
    local base = directory .. '/' .. file_of(built.name)
    local shown = parse.of(built.raw)
    local entry =
        { name = built.name, subject = shown.subject, to = shown.to, text = base .. '.txt', eml = base .. '.eml' }

    if built.letter.html ~= nil then
        entry.html = base .. '.html'
    end

    local err = put(entry.eml, built.raw)
        or put(entry.text, BOM .. built.letter.text)
        or (entry.html ~= nil and put(entry.html, BOM .. built.letter.html) or nil)

    if err ~= nil then
        return nil, err
    end

    return entry
end

--- Кладёт собранные письма в каталог и оглавление к ним.
---@param directory string
---@param letters { name: string, letter: table, raw: string }[]
---@return TntMailPreview|nil files
---@return string|nil err
function Module.write(directory, letters)
    local made, failure = fs.make_tree(directory)

    if not made then
        return nil, tostring(failure)
    end

    local entries = {}

    for _, built in ipairs(letters) do
        local entry, err = written(directory, built)

        if entry == nil then
            return nil, err
        end

        table.insert(entries, entry)
    end

    local index = directory .. '/index.html'
    local err = put(index, index_of(entries))

    if err ~= nil then
        return nil, err
    end

    return { index = index, letters = entries }
end

--- Вход цели сборки: письма модуля — в каталог. Код выхода процесса.
---
--- Модуль писем называет тот, кто зовёт цель; он отдаёт письма,
--- собранные `mail.letters`, с объявлениями и данными примеров.
---@param name string|nil Модуль писем
---@param directory string|nil Куда класть; по умолчанию `var/mail-preview`
---@return integer code 0 — удача, 1 — отказ, 2 — неверный вызов
function Module.main(name, directory)
    if name == nil or name == '' then
        source().complain('назовите модуль писем: make mail-preview LETTERS=app.mail')

        return 2
    end

    local ok, files, err = pcall(function()
        return require(name):preview(directory or Module.DIRECTORY)
    end)

    if not ok or files == nil then
        source().complain(('письма %s не собраны: %s'):format(name, tostring(ok and err or files)))

        return 1
    end

    source().say(files.index)

    for _, entry in ipairs(files.letters) do
        source().say(entry.html or entry.text)
    end

    return 0
end

return Module
