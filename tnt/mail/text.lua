--- Простой текст письма из его разметки.
---
--- Письмо с разметкой уходит двумя частями: простой текст первой,
--- разметка второй. Держать текст вторым видом рядом с разметкой — значит
--- однажды поправить одно и забыть другое: ссылка подтверждения в тексте
--- ведёт на старый адрес, и получатель, чья программа показывает простой
--- текст, подтвердить почту не может. Поэтому текст выводится из той же
--- разметки, какой её увидит браузер:
---
--- - `head`, `style`, `script`, `title` и заметки `<!-- -->` выпадают
---   целиком, объявления `<!DOCTYPE>` и `<?xml?>` — тоже;
--- - пробелы и переводы строк разметки сжимаются в один пробел; внутри
---   `pre` они остаются как есть;
--- - абзац, заголовок, список, таблица, цитата, `pre` и `hr` отделены
---   пустой строкой, а `br`, `div`, строка таблицы и пункт списка
---   начинаются с новой строки;
--- - пункт списка — «- » либо «1. », вложенный — с отступом;
--- - ссылка — текст и адрес в скобках; ссылка, текст которой и есть адрес,
---   — адрес один раз, а ссылка внутри страницы (`#…`) — только текст;
--- - картинка — её `alt`;
--- - знаки `&amp;`, `&laquo;`, `&#8212;` — буквами UTF-8, управляющие
---   знаки из них — нет;
--- - строка из двух дефисов — разделитель подписи `-- ` с пробелом
---   (RFC 3676, 4.3): по нему почтовые программы узнают подпись и не
---   цитируют её в ответе, а пробел в конце строки сжатие съело бы.

local utf8 = require('utf8')

local Module = {}

--- Знак отступа, который переживает сжатие пробелов и обрезку строк.
---
--- Отступ вложенного пункта и пробелы внутри `pre` пишутся им, а в пробел
--- превращаются последними. Во входе такого знака быть не может: он
--- выбрасывается до разбора, как и два знака разрыва ниже.
local MARK = '\1'

--- Мягкий разрыв строки: следующий текст — с новой строки, если он ещё
--- не с неё. Конец пункта и начало следующего — один перевод строки,
--- а не пустая строка между пунктами.
local LINE_BREAK = '\2'

--- Мягкий разрыв абзаца: между абзацами ровно одна пустая строка,
--- сколько бы их ни закрылось и ни открылось подряд.
local PARAGRAPH_BREAK = '\3'

--- Множество из строки слов.
---@param words string
---@return table<string, boolean>
local function set(words)
    local found = {}

    for _, word in ipairs(words:split()) do
        found[word] = true
    end

    return found
end

--- Элементы, которые выпадают вместе с содержимым.
local HIDDEN = set('head style script title template')

--- Элементы-абзацы: до и после них пустая строка. Списки — тоже, если
--- они не вложены в пункт (`tag`).
local PARAGRAPH = set('p h1 h2 h3 h4 h5 h6 table blockquote pre hr')

--- Элементы-строки: начинаются с новой строки и кончаются ею.
local LINE = set('div tr li dt dd section article header footer center')

--- Знаки по имени: те, что пишут в письмах, и те, что пишет сама
--- разметка. Незнакомое имя остаётся как есть — гадать нечего.
local ENTITIES = {
    amp = '&',
    lt = '<',
    gt = '>',
    quot = '"',
    apos = "'",
    nbsp = utf8.char(0xA0),
    laquo = '«',
    raquo = '»',
    mdash = '—',
    ndash = '–',
    hellip = '…',
    copy = '©',
    reg = '®',
    trade = '™',
    euro = '€',
    bull = '•',
    middot = '·',
    times = '×',
    lsquo = '‘',
    rsquo = '’',
    ldquo = '“',
    rdquo = '”',
    bdquo = '„',
}

--- Знак по имени либо номеру; пусто — оставить запись как есть.
---
--- Управляющий знак, суррогат и номер за пределом Юникода не выводятся:
--- из разметки они попали бы в текст письма байтами, которые портят
--- строку у получателя.
---@param numeric string `#` у записи номером, пусто у записи именем
---@param word string Имя либо номер
---@return string|nil
local function character(numeric, word)
    if numeric == '' then
        return ENTITIES[word]
    end

    local hex = word:match('^[xX]') and word:sub(2)
    local code

    -- Десятичная запись — только цифры: `tonumber` прочёл бы `1e5`
    -- числом с порядком, и с основанием 10 тоже.
    if hex ~= nil then
        code = tonumber(hex, 16)
    elseif word:find('%D') == nil then
        code = tonumber(word)
    end

    if code == nil or code < 32 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
        return nil
    end

    return utf8.char(code)
end

--- Переводит записи знаков в буквы UTF-8.
---@param text string
---@return string
local function decode(text)
    return (text:gsub('&(#?)(%w+);', character))
end

--- Значение свойства тега: в кавычках, в апострофах либо словом.
---
--- Имя свойства ищется без оглядки на регистр, а значение берётся как
--- написано: адрес ссылки в верхнем регистре — уже другой адрес.
---@param attributes string Всё, что стоит в теге после имени
---@param name string Имя свойства строчными
---@return string|nil
local function attribute(attributes, name)
    local _, stop = attributes:lower():find('%f[%w]' .. name .. '%s*=%s*')

    if stop == nil then
        return nil
    end

    local rest = attributes:sub(stop + 1)

    local value = rest:match('^"([^"]*)"') or rest:match("^'([^']*)'") or rest:match('^[^%s>]*')

    return decode(value --[[@as string]])
end

--- Разбирает разметку на куски: текст и теги по порядку.
---
--- Текст перед тегом берёт ленивый захват, а хвост после последнего
--- тега — сама замена: у неё нет места начала, которое пришлось бы
--- считать. Знак `<`, за которым нет имени тега, — текст.
---@param html string
---@return table[] tokens `{ text }` либо `{ name, closing, attributes }`
local function tokens(html)
    local source = html:gsub('[' .. MARK .. LINE_BREAK .. PARAGRAPH_BREAK .. ']', '')
        :gsub('<!%-%-.-%-%->', '')
        :gsub('<[!?][^>]*>', '')
    local found = {}

    local rest = source:gsub('(.-)<(/?)(%a%w*)([^>]*)>', function(before, closing, name, attributes)
        table.insert(found, { text = before })
        table.insert(found, { name = name:lower(), closing = closing == '/', attributes = attributes })

        return ''
    end)

    table.insert(found, { text = rest })

    return found
end

---@class TntMailTextState
---@field out string[] Выведенное по порядку
---@field hidden string|nil Внутри какого скрытого элемента мы сейчас
---@field pre integer Глубина `pre`
---@field lists { ordered: boolean, count: integer }[] Открытые списки
---@field links { href: string|nil, from: integer }[] Открытые ссылки

--- Текст между тегами.
---@param state TntMailTextState
---@param chunk string
local function text(state, chunk)
    if state.hidden ~= nil then
        return
    end

    if state.pre > 0 then
        table.insert(state.out, (decode(chunk):gsub(' ', MARK)))
    else
        table.insert(state.out, decode((chunk:gsub('%s+', ' '))))
    end
end

--- Начало пункта списка: номер у нумерованного, дефис у прочих.
---@param state TntMailTextState
local function item(state)
    local depth = #state.lists
    local list = state.lists[depth]
    local marker = '- '

    if list ~= nil and list.ordered then
        list.count = list.count + 1
        marker = list.count .. '. '
    end

    -- Отступ — по два знака на уровень вложенности; пункт вне списка
    -- и пункт верхнего уровня его не получают: `rep` с числом меньше
    -- единицы отдаёт пустую строку.
    table.insert(state.out, MARK:rep(2 * depth - 2) .. marker)
end

--- Конец ссылки: адрес в скобках после текста.
---@param state TntMailTextState
local function link_closed(state)
    local link = table.remove(state.links)

    if link == nil or link.href == nil or link.href == '' or link.href:find('^#') ~= nil then
        return
    end

    local label = table.concat(state.out, '', link.from):gsub('%s+', ' '):match('^ ?(.-) ?$')
    local href = link.href

    if label == '' then
        table.insert(state.out, href)
    elseif label ~= href and label ~= (href:gsub('^mailto:', '')) then
        table.insert(state.out, (' (%s)'):format(href))
    end
end

--- Список открылся либо закрылся.
---@param state TntMailTextState
---@param token { name: string, closing: boolean }
local function listed(state, token)
    if token.closing then
        table.remove(state.lists)
    else
        table.insert(state.lists, { ordered = token.name == 'ol', count = 0 })
    end
end

--- Тег: разрыв строки, пункт, ссылка, картинка.
---@param state TntMailTextState
---@param token { name: string, closing: boolean, attributes: string }
local function tag(state, token)
    local name = token.name

    if state.hidden ~= nil then
        if token.closing and name == state.hidden then
            state.hidden = nil
        end

        return
    end

    if HIDDEN[name] and not token.closing then
        state.hidden = name

        return
    end

    if name == 'pre' then
        state.pre = math.max(state.pre + (token.closing and -1 or 1), 0)
    end

    if name == 'ul' or name == 'ol' then
        listed(state, token)

        -- Вложенный список идёт строками своего пункта, а не абзацем.
        local depth = #state.lists - (token.closing and 0 or 1)

        table.insert(state.out, depth > 0 and LINE_BREAK or PARAGRAPH_BREAK)
    elseif PARAGRAPH[name] then
        table.insert(state.out, PARAGRAPH_BREAK)
    elseif LINE[name] then
        table.insert(state.out, LINE_BREAK)
    elseif name == 'br' then
        table.insert(state.out, '\n')
    end

    if token.closing then
        if name == 'a' then
            link_closed(state)
        end
    elseif name == 'li' then
        item(state)
    elseif name == 'a' then
        table.insert(state.links, { href = attribute(token.attributes, 'href'), from = #state.out + 1 })
    elseif name == 'img' then
        table.insert(state.out, attribute(token.attributes, 'alt') or '')
    end
end

--- Разрывы подряд — один: пустая строка, если среди них есть разрыв
--- абзаца либо два перевода строки `br` или `pre`, иначе перевод строки.
--- Больше одной пустой строки подряд текст не держит.
---@param run string
---@return string
local function broken(run)
    if run:find(PARAGRAPH_BREAK) ~= nil or select(2, run:gsub('\n', '')) >= 2 then
        return '\n\n'
    end

    return '\n'
end

--- Сводит выведенное в строки: пробелы по краям строк прочь, пустых
--- строк подряд не больше одной, по краям текста — ни одной.
---@param raw string
---@return string
local function finish(raw)
    local lines = {}
    local breaks = LINE_BREAK .. PARAGRAPH_BREAK
    local joined = raw:gsub(('[ \n%s]*[%s][ \n%s]*'):format(breaks, breaks, breaks), broken)

    for _, line in ipairs(joined:gsub(' +', ' '):split('\n')) do
        local trimmed = line:match('^ ?(.-) ?$') --[[@as string]]

        if trimmed == '--' then
            trimmed = '-- '
        end

        table.insert(lines, (trimmed:gsub(MARK, ' ')))
    end

    return table.concat(lines, '\n'):gsub('\n\n+', '\n\n'):match('^\n*(.-)\n*$') --[[@as string]]
end

--- Простой текст из разметки; пустота — пустая строка.
---@param html string|nil
---@return string
function Module.of(html)
    if html == nil then
        return ''
    end

    ---@type TntMailTextState
    local state = { out = {}, pre = 0, lists = {}, links = {} }

    for _, token in ipairs(tokens(html)) do
        if token.name == nil then
            text(state, token.text)
        else
            tag(state, token)
        end
    end

    return finish(table.concat(state.out))
end

return Module
