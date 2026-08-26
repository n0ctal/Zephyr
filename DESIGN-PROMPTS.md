# Zephyr — промты для отрисовки макетов

Для генератора картинок. Пять направлений, намеренно **разных**, а не оттенков
одного. К каждому — что рисовать, и отдельно что НЕ рисовать: генераторы любят
добавлять то, чего не просили, и именно это чаще всего убивает минимализм.

Общее для всех: приложение живёт в строке меню macOS, окно настроек — десять
вкладок, интерфейс на английском. Аудитория — обычный человек, у которого вместо
одной программы стоит десяток. Значит на макете не должно быть ничего, что
требует объяснения.

---

## Как пользоваться

Каждый промт самодостаточен — копируй целиком. Если хочешь сравнить направления
честно, проси **одну и ту же вкладку** (Cooling) во всех пяти.

---

## 1. 間 — пустота как материал

```
A macOS settings window for a laptop-control utility called Zephyr, designed in
the tradition of Japanese graphic minimalism — Kenya Hara, MUJI, the idea of
"ma": emptiness as a material, not as leftover space.

Window: 840×700, light warm off-white background (#FAF9F6), no card borders, no
boxes, no shadows inside the content. Ten tab labels in a single quiet
horizontal row at the top — Cooling, Power, Graphics, Battery, Display,
Keyboard, Pointer, Awake, Profiles, Menu Bar — set in light-weight type, the
active one marked only by a 1px underline in a single accent colour.

Content shown: the Cooling tab. A checkbox labelled "Enable Cooling". One line
of explanatory text in grey. A segmented choice: Firmware / Temperature curve /
Fixed speed. Two labelled sliders with the number written out beside each. A
small section headed "Throttling" with two lines of plain status text.

Typography: one sans-serif family, two weights only. Generous line height.
Numbers in a monospaced face so they align.

Palette: off-white ground, near-black text (#1A1A1A), one grey for secondary
text, and exactly one accent — a muted indigo. Nothing else has colour.

Space: at least 40% of the window is empty. Vertical rhythm on a strict 8px
grid. No dividers except hairlines at 10% opacity.

Do NOT include: gradients, drop shadows, rounded cards, icons beside labels,
colour-coded status pills, a sidebar, a toolbar, decorative illustration, or any
element that is not one of the controls listed above.
```

## 2. Измерительный прибор

```
A macOS settings window for Zephyr, a laptop-control utility, designed like a
precision measuring instrument in the Dieter Rams tradition — restrained, but
unashamed that its purpose is to show numbers.

Window: 840×700, neutral light grey ground (#F2F2F0). Ten tab labels across the
top in a plain row. The content area is the Cooling tab.

Content: a checkbox "Enable Cooling"; a three-way segmented control; two
horizontal sliders, each with its value in a bordered numeric field at the right
end, in monospaced digits with a unit suffix; below a hairline rule, a
"Throttling" block showing a current value and a session minimum.

The instrument character comes from restraint, not decoration: tick marks only
where a slider has few steps, numeric fields aligned on a common right edge,
units set smaller and in grey, and every number monospaced so nothing shifts as
values change.

Palette: grey ground, black text, one signal colour (a warm amber) used only for
a value that is out of its normal range. No other colour anywhere.

Do NOT include: gauges, dials, skeuomorphic metal or glass, LED-style displays,
graphs, charts, coloured backgrounds behind sections, or any icon at all.
```

## 3. Тушь на бумаге

```
A macOS settings window for Zephyr, drawn as if printed: sumi ink on paper.

Window: 840×700. Ground is warm paper white (#FBF8F1) with absolutely no
texture — the paper feeling comes from the colour and the margins, not from a
grain overlay. Text is ink black. A single vermilion accent (#C1362F) appears
exactly twice in the whole window: on the active tab marker and on one enabled
control.

Content: the Cooling tab — an enable checkbox, one line of grey explanatory
text, a segmented choice of three, two sliders with their numbers, and a short
status block.

Layout follows a printed page: wide outer margins, a single column, no
horizontal centring, everything aligned to one left edge. Section headings are
set in the same size as body text but in a heavier weight, separated by space
rather than by rules.

Do NOT include: brush strokes, calligraphy, cherry blossoms, bamboo, rice-paper
texture, wave patterns, or any literal Japanese motif. The reference is the
restraint of the printing, not the imagery.
```

## 4. Тёмное стекло

```
A macOS settings window for Zephyr in dark mode, native to the platform and
content-first.

Window: 840×700 on near-black (#1C1C1E) with the standard macOS translucent
title bar. Ten tabs in a single row, the active one on a subtly lighter fill.

Content: the Cooling tab — an enable checkbox, grey explanatory line, a
segmented control, two sliders each with an editable numeric field beside it,
and a "Throttling" section of two text lines.

Everything that is not text or a control is absent: no panels, no cards, no
borders. Separation is done with space and with hairlines at 8% white. Controls
use the system blue only when active; everything else is white at three
opacities — 100% for values, 70% for labels, 45% for explanations.

Do NOT include: glassmorphism blur panels, neon glows, gradients, coloured
accent backgrounds, graphs, icons, or a sidebar.
```

## 5. Одна строка — одна мысль

```
A macOS settings window for Zephyr, laid out as a list of plain statements
rather than as a form.

Window: 840×700, light ground. Ten tabs at the top. The Cooling tab shows a
vertical list where every row is one complete idea: a control on the left and,
where a value exists, that value on the right edge of the same row. Rows are
separated by space alone.

Rows shown, in order: "Enable Cooling" with a switch; "Fans follow" with a
three-way segmented control; "Start lifting the fans at" with 55 °C; "Reach full
speed at" with 85 °C; "The CPU is running at full speed" as a statement with no
control; "Nothing has been capped since Zephyr started" in smaller grey text.

The point is that the window can be read top to bottom as sentences, and nothing
needs a legend. Left edges of all labels align; right edges of all values align.

Palette: white ground, near-black text, one grey, one accent for active
switches. Nothing else.

Do NOT include: section headers, group boxes, cards, icons, colour coding,
tooltips, badges, or any two-column form layout with labels right-aligned
against fields.
```

---

## Отдельно: строка меню

```
A macOS menu bar, dark, shown close-up as a horizontal strip. At the right end,
a compact status readout from an app called Zephyr, drawn as one continuous line
of small monospaced text with even spacing between fields: a small solid
battery pill with "100" knocked out of it, then "50°", then "1834 rpm", then
"2.3 GHz", then a row of sixteen thin vertical bars hanging from the top edge
representing per-core CPU load, then "57 %". Beside it, the ordinary macOS
clock and Wi-Fi icons for scale.

The battery pill is a solid rounded shape with no outline: the filled part is
white, the remainder grey, matching the iOS 27 style.

Do NOT include: colour other than the white text and grey battery remainder, any
app icon, any dropdown menu, or a light menu bar.
```

## Отдельно: иконка приложения

```
A macOS app icon for "Zephyr", a laptop-control utility. Rounded-square macOS
icon shape. The subject is a single gesture suggesting moving air — one
continuous curved line, or two, with nothing else in the frame. Flat, no
gradient mesh, no glow, no 3D. Two colours at most on a plain ground.

The icon should read at 32×32: if the shape needs detail to be recognised, it is
wrong.

Do NOT include: fans, propellers, laptops, gauges, thermometers, lightning
bolts, letters, wordmarks, clouds with faces, or wind drawn as swirls with
particles.
```

---

# Боковой список вместо верхних вкладок

Десять пунктов в боковом списке — много, поэтому сначала объединение по смыслу.
Предлагаемая семёрка, и почему именно так:

| Раздел | Что вобрал | Почему вместе |
|---|---|---|
| **Thermals** | Cooling + Power | Вентиляторы, турбо, лимит мощности и троттлинг — четыре ответа на один вопрос: насколько горячо и насколько сильно |
| **Graphics** | — | Какая видеокарта рисует. Отдельная тема, ни к чему не примыкает |
| **Battery & Sleep** | Battery + Awake | Оба про то, что происходит со временем: не перезаряжать и не засыпать |
| **Display** | — | Яркость и разрешения |
| **Input** | Keyboard + Pointer | Обе про то, чем человек управляет машиной |
| **Profiles** | — | Движок правил, связывающий остальные |
| **Menu Bar** | — | Не трогает железо вовсе, только вид |

**Развилка, которую и надо увидеть глазами.** Тумблер прямо в строке бокового
списка — приём не родной для macOS: у Apple в боковом списке только имя и
значок. Он экономит клик, но легко превращает спокойный список в пёстрый, а у
объединённых разделов появляется два уровня переключателей (общий в списке и
частные внутри). Поэтому ниже два промта — с тумблерами в списке и без.
Просить оба и сравнить.

## 6. Боковой список, тумблер в строке

```
A macOS settings window for a laptop-control utility called Zephyr, laid out
like macOS System Settings: a sidebar on the left, a content pane on the right.

Window: 900×640, dark (#1C1C1E), standard macOS traffic lights, translucent
title bar.

Sidebar (240px wide, slightly darker than the pane): seven rows, each with a
small monochrome glyph, a label, and — this is the unusual part — a small
switch at the right edge of the row. Rows: Thermals, Graphics, Battery & Sleep,
Display, Input, Profiles, Menu Bar. The switches are on for Thermals and
Battery & Sleep, off for the rest. The selected row (Thermals) has the standard
blue selection fill.

Content pane: the Thermals section. A large title "Thermals" with one grey line
under it. Then two grouped blocks in the macOS rounded-group style: the first
headed "Fans" with a three-way segmented control and two labelled value rows;
the second headed "Power" with a switch row "Disable Turbo Boost" and two value
rows for sustained and burst watts. Below, a plain two-line status block about
throttling.

Every value sits on the right edge of its row, in monospaced digits with a grey
unit. Rows inside a group are separated by hairlines; groups by space.

Palette: dark ground, white text at three opacities, system blue only for
selection and active switches. No other colour.

Do NOT include: coloured app-style icons in the sidebar (monochrome glyphs
only), a search field, a back/forward arrow pair, gradients, shadows inside the
pane, graphs, or more than seven sidebar rows.
```

## 7. Боковой список, тумблер внутри раздела

```
The same window as above — macOS System Settings layout, dark, 900×640, a 240px
sidebar of seven rows: Thermals, Graphics, Battery & Sleep, Display, Input,
Profiles, Menu Bar, each with a small monochrome glyph and a label only.

The difference: there are no switches in the sidebar. Instead, the very first
thing in the content pane is a single full-width switch row reading "Enable
Thermals", followed by one grey line explaining what turning it on will do.
Everything below that row is visibly dimmed to about 40% opacity, because the
section is off — so the state of the section is stated once, in words, in the
place where its settings are.

Content below the switch: a "Fans" group with a three-way segmented control and
two labelled value rows; a "Power" group with a Turbo Boost switch and two watt
rows; a plain throttling status block.

Palette and rules as before: dark ground, white at three opacities, system blue
only for selection and active controls, hairlines inside groups, space between
them.

Do NOT include: switches in the sidebar, coloured icons, a search field,
navigation arrows, gradients, graphs, or badges.
```

## 8. То же, но светлое и разрежённое

```
The macOS System Settings sidebar layout again — 900×640, sidebar of seven rows
(Thermals, Graphics, Battery & Sleep, Display, Input, Profiles, Menu Bar) —
but light, and stripped further.

Ground is warm off-white (#FAF9F6). The sidebar has no fill of its own and no
separator line; it is set apart by space alone. Sidebar rows have no glyphs at
all, only labels, and the selected one is marked by a single accent-coloured
dot to the left of its text rather than by a filled bar.

The content pane has no grouped boxes. Each setting is one row on a plain
ground: label on the left, control or value on the right, rows separated by
generous space and nothing else. Section headings ("Fans", "Power") are set in
the body size but heavier, with space above them instead of a rule.

One accent colour, used only for the selected sidebar dot and for active
controls. At least a third of the window is empty.

Do NOT include: rounded group containers, hairline dividers, icons, a sidebar
background fill, shadows, or colour beyond the single accent.
```

---

# Настоящее содержимое вкладки Cooling

Первый заход генератор придумал правдоподобные, но чужие подписи — «Fan target
temperature», «Throttling: No». Судить макет по выдуманному содержимому нельзя:
непонятно, годится ли он для настоящего. Этот блок вставлять в любой промт
вместо описания содержимого.

```
The content is the Cooling section, and these are its real controls — use these
exact words, do not invent plausible-sounding alternatives:

  Checkbox: "Enable Cooling"
  Grey explanatory line: "Drive the fans yourself instead of leaving them to the
  firmware, and see when heat is capping the CPU."

  Segmented control labelled "Fans follow": Firmware / Temperature curve / Fixed speed

  With "Temperature curve" chosen, two value rows:
    "Start lifting the fans at"   55 °C
    "Reach full speed at"         85 °C

  A section headed "Throttling" with two lines of plain text:
    "The CPU is running at full speed."
    "Nothing has been capped since Zephyr started."
  (when it is capped these read, for example, "The firmware is holding the CPU at
  60 % of full speed right now." and "Lowest this session: 60 % · held back for
  4 minutes")

Every value row is a label on the left and, on the right, a slider followed by
an editable numeric field and a grey unit. The number is editable because a
slider cannot be aimed at 80.

Sliders have NO tick marks. A tick per step is unreadable past a few dozen and
the fan range has thousands.

Colour: any accent used for a selected segment must not be red. Red is reserved
for a value that is wrong or dangerous, and spending it on ordinary selection
leaves nothing to say "look here" with.
```

## Ещё одно наблюдение по первым макетам

Десять вкладок в верхнем ряду физически тесны — в самом узком варианте подписи
уже нечитаемы. Это не придирка к отрисовке, а та же причина, по которой живое
окно пришлось расширить до 820 точек. Ещё один довод за боковой список.
