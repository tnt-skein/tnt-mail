--- Письма-образцы: подтверждение почты и письмо об ответе.
---
--- Их берут проверки писем и цель `make mail-preview LETTERS=…`: так
--- предпросмотр в дереве есть на чём посмотреть, а проверки сверяют
--- то же, что увидит человек в браузере.

local fio = require('fio')
local mail = require('tnt.mail')
local template = require('tnt.template')

--- Каталог видов-образцов — соседний с этим файлом.
---
--- Путь берётся от самого файла, а не от рабочего каталога: образцы
--- зовут и из корня репозитория пакета, и из корня дерева, где пакет
--- лежит среди других, и путь от корня разошёлся бы между ними.
local this_file =
    assert(debug.getinfo(1, 'S'), 'нет отладочной информации о файле').source:sub(2)
local VIEWS = fio.pathjoin(fio.dirname(fio.dirname(this_file)), 'views')

local letters = mail.letters({
    views = template.new({ path = VIEWS }),
    from = { name = 'Пример', address = 'noreply@example.org' },
})

letters:declare('confirm', {
    subject = 'Подтвердите почту',
    to = function(data)
        return { name = data.name, address = data.email }
    end,
    view = 'mail.confirm',
    example = { name = 'Мария', email = 'maria@example.org', link = 'https://example.org/confirm?token=a1&user=7' },
})

letters:declare('replied', {
    subject = function(data)
        return ('Ответ в теме «%s»'):format(data.thread)
    end,
    to = function(data)
        return data.email
    end,
    view = 'mail.replied',
    text_view = 'mail.replied_text',
    example = function()
        return {
            name = 'Мария',
            email = 'maria@example.org',
            thread = 'Отставание реплики',
            reply = "Перезапустили узел <storage-001-b> — O'Brien",
            link = 'https://example.org/threads/7',
        }
    end,
})

return letters
