# Иконка PangoZip

Перерисована встроенным инструментом `image_gen` по изображению панголина, предоставленному пользователем 11.10.2026.

- `AppIcon-master.png`: исходник 1024×1024 с прозрачными внешними углами.
- `AppIcon.iconset`: PNG для macOS, 16, 32, 128, 256, 512 точек в вариантах 1× и 2× (до 1024 пикселей).
- `AppIcon.icns`: готовая иконка приложения и фонового помощника.
- `scripts/build-icon.sh`: воспроизводимое масштабирование через macOS `sips` и упаковка через `iconutil`; запускается при сборке приложения.

## Запрос перерисовки

Use case: stylized-concept. Asset type: final macOS application icon master for PangoZip, 1024x1024 square. Input image is the visual reference: faithfully redraw this same curled golden pangolin, its head on the left looking toward lower left, small dark glossy eye, nose and visible tiny paws, tail wrapping into an almost circular protective ball. Preserve the reference pose, proportions, friendly expression and overlapping large sculpted warm gold and bronze scales. High quality polished sculpted 3D illustration, crisp clean contour, soft warm light from upper left, beautiful restrained scale shading. Center the whole animal with approximately 8% safe margin; do not crop any scales or feet. Dark midnight navy background like reference, subtle grounding shadow. Full-bleed square artwork, background reaches all edges, no rounded corners baked in, no external frame, no lettering, no logo, no watermark. Simplify very tiny details for legibility at app-icon sizes without changing the animal identity. Output a single square icon artwork.

## Запрос финальной формы

Precise-object-edit for final macOS application icon. Preserve exactly this pangolin artwork, composition, gold scales and navy background. Change ONLY the outer icon silhouette: make the navy square into a standard macOS app icon rounded square (smooth continuous corners with radius around 22% of the tile edge), centered on a genuinely transparent square canvas, tile occupies 90% of canvas width and height. Animal remains fully inside the navy tile; no cropping of the pangolin. All pixels outside the rounded navy tile must be transparent alpha, not white or checkerboard. No added glow, text, bevel, frame or perspective. Square 1024x1024 output. Preserve original illustration faithfully.
