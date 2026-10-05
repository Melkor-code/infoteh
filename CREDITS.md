# Откуда что взято

Пока в проекте только наши тексты и числа из открытых паспортов. Картинок и кода движка здесь ещё нет.

Когда появятся, сюда дописываем три колонки: что взяли, откуда ссылка, какая лицензия.

Уже используем как источники чисел, не как код:

- Геоскан Пионер Mini, PDF характеристик: https://download.geoscan.ru/pioneer/upload/Docs/Pioneer_Mini_tech_spec.pdf
- Геоскан Пионер FPV, PDF характеристик: https://download.geoscan.ru/pioneer/upload/Docs/Geoscan-Pioneer-FPV-characteristics.pdf?v3
- Геоскан Пионер FPV, страница со скоростью: https://geoscan.education/pioneer-fpv
- DJI Phantom 4 Pro, спецификация: https://www.dji.com/support/product/phantom-4-pro

Это не официальные модели производителей.

Идея, как ветвится дерево, разобрана по открытому плагину gdTree3D: https://github.com/JekSun97/gdTree3D . Там обёртка над proctree (Paul Brunt, 2012; перенос на C++ — Jari Komppa, 2015). В проект не копировались ни их библиотека, ни исходник. Сетка, шейдер и карточки листвы написаны в `scripts/proc_tree.gd`.

Как качается трава, разобрано по описанию пакета EmacE Art «Godot Stylized Vegetation Wind Shader»: https://store.godotengine.org/asset/emace-art/godot-stylized-vegetation-wind-shader/ . Три слоя ветра, гнётся только кончик, снег садится сверху вниз. Их файлы не скачивались и не вставлялись: у пакета своя лицензия, шейдер написан у нас.
