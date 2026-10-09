# CREDITS

Проект является учебным прототипом. Модели аппаратов и их числовые профили не являются официальными продуктами Геоскана или DJI.

## Модели аппаратов

В игре используются предоставленные учебные GLB из `data/models/flight/`:

- `drone.glb` — профиль Геоскан Пионер Mini;
- `geoscan_pioneer_fpv.glb` — профиль Геоскан Пионер FPV;
- `dji_phantom.glb` — профиль DJI Phantom 4 Pro.

Названия и паспортные ссылки профилей приведены в JSON-файлах `data/vehicles/`. Числа, которые не опубликованы в паспорте, помечены в коде как допущения.

## Растительность карты

- Трава: пакет EmacEArt Stylized Grass, EmacEArt (Maciej), 2026. Условия использования сохранены в `assets/map/grass/LICENSE.txt`.
- Деревья: gdTree3D, Artyom Bozhko и участники, лицензия MIT. Копия лицензии находится в `assets/map/trees/LICENSE.md`.

Базовые сетки и текстуры карты поставляются вместе с проектом. Скрипт `scripts/proc_tree.gd` использует локальное правило развилок; сторонняя библиотека генерации не входит в исполняемую игру.

## Паспортные источники

- Геоскан Пионер Mini: https://download.geoscan.ru/pioneer/upload/Docs/Pioneer_Mini_tech_spec.pdf
- Геоскан Пионер FPV: https://download.geoscan.ru/pioneer/upload/Docs/Geoscan-Pioneer-FPV-characteristics.pdf?v3
- Геоскан Пионер FPV: https://geoscan.education/pioneer-fpv
- DJI Phantom 4 Pro: https://www.dji.com/support/product/phantom-4-pro
