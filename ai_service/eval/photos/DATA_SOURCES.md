# Источники фото-эталона НарядAI

Набор собран из открытых источников; авторство и лицензию нужно указывать при публикации. Страницы VisA, airsoft и test-yfiry указывают CC BY 4.0. Для `project-7mbdj/999-krc03` ссылка сейчас не открывается для независимой проверки, поэтому его лицензию следует подтвердить у автора до распространения производных изображений.

Для демонстрации/презентации `999-krc03` запрещён. Генерируйте отдельный `demo_safe/` через `python -m eval.photos.select_demo`: скрипт выбирает только два подтверждённых конвейерных источника и записывает атрибуцию в `manifest.csv`. Старая папка `demo/` не проверена для показа.

- VisA — https://github.com/amazon-science/spot-diff (Zou et al., ECCV 2022)
- airsoft/conveyor-belt-defects — https://universe.roboflow.com/airsoft/conveyor-belt-defects
- project-7mbdj/999-krc03 — https://universe.roboflow.com/project-7mbdj/999-krc03
- test-yfiry/conveyor-belt-damage-ucjlj — https://universe.roboflow.com/test-yfiry/conveyor-belt-damage-ucjlj

## Важно для метрик

- `proxy` (VisA): дефектный и исправный объект одного класса, НЕ один и тот же экземпляр.
- `semi_synthetic`: «после» получено закрашиванием размеченной области дефекта (cv2.inpaint), а не реальным ремонтом. Показывать отдельной строкой.
- `real_same_image`: «после» = то же фото, проблема не устранена.
- Ни одна метрика здесь не является точностью на реальном ремонте.

## Состав (seed=42)

- cross_class/other_equipment: 60
- proxy/fixed: 30
- proxy/not_fixed: 30
- real_same_image/not_fixed: 30
- semi_synthetic/fixed: 30
- дубли: 200
