# Откуда что взято

В проект включены предоставленные пользователем модели аппаратов и ресурсы карты. Исходные наборы сохранены отдельно от рабочих копий.

| Ресурс | Источник | Условия |
|---|---|---|
| Три модели аппаратов | `data/models/drone_godot`, `geoscan_pioneer_fpv`, `dji_phantom_godot` | Предоставлены пользователем; игровые интерпретации по фото, не официальные модели производителей |
| Трава: сетка, текстуры, материалы, шейдер | `map/EmacEArtStylizedGrass`, EmacEArt (Maciej), 2026 | EmacEArt Asset License; копия в `assets/map/grass/LICENSE.txt`. Использование внутри проекта разрешено, распространение ассетов отдельным набором запрещено |
| Сетки деревьев, текстуры коры и листвы | `map/gdTree3D-main`, Artyom Bozhko и участники | MIT; копия в `assets/map/trees/LICENSE.md` |

Уже используем как источники чисел, не как код:

- Геоскан Пионер Mini, PDF характеристик: https://download.geoscan.ru/pioneer/upload/Docs/Pioneer_Mini_tech_spec.pdf
- Геоскан Пионер FPV, PDF характеристик: https://download.geoscan.ru/pioneer/upload/Docs/Geoscan-Pioneer-FPV-characteristics.pdf?v3
- Геоскан Пионер FPV, страница со скоростью: https://geoscan.education/pioneer-fpv
- DJI Phantom 4 Pro, спецификация: https://www.dji.com/support/product/phantom-4-pro

Это не официальные модели производителей.

Деревья сгенерированы предоставленным плагином gdTree3D: https://github.com/JekSun97/gdTree3D . Там обёртка над proctree (Paul Brunt, 2012; перенос на C++ — Jari Komppa, 2015). Генератор сохранён в `map/tree_baker`, готовые сетки — в `assets/map/trees`. В основном проекте используется собственный адаптированный шейдер `scripts/proc_tree.gd`; DLL требуется только для повторной генерации.

Трава использует предоставленный пакет EmacEArt Stylized Grass и его шейдер с ветром и снегом. Пути материалов адаптированы к `assets/map/grass`, размещение и параметры ветра задаёт `scripts/island_field.gd`. Исходные уведомления об авторстве сохранены.
