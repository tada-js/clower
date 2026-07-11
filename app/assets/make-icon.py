#!/usr/bin/env python3
"""raw/idle.png의 첫 프레임 → 정사각 1024 아이콘 마스터(icon-master.png).

Finder·dmg에 뜨는 앱 아이콘의 소스다(메뉴바 아이콘은 런타임에 따로 그림).
slice.py의 프레임 분리·투명화 로직을 재사용해 다 자란 새싹(쉬는 상태) 한 프레임을
원본 해상도로 뽑아 정사각 캔버스 중앙에 여백을 두고 배치한다.

사용법: python3 make-icon.py  (→ icon-master.png). 이후 make-icon.sh가 .icns로 만든다.
"""
import os
from PIL import Image
from slice import find_frames, content_band, normalize

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "raw", "idle.png")   # 다 자란 새싹 = 앱의 "쉬는" 얼굴, 아이콘에 어울림
OUT = os.path.join(HERE, "icon-master.png")
SIZE = 1024
MARGIN = 0.12   # 정사각 대비 여백 비율(macOS 아이콘 그리드 여백 흉내)


def main():
    img = Image.open(SRC).convert("RGBA")
    l, r = find_frames(img)[0]
    top, bot = content_band(img)
    frame = normalize(img.crop((l, top, r, bot)))
    content = round(SIZE * (1 - 2 * MARGIN))
    scale = content / max(frame.width, frame.height)
    w, h = round(frame.width * scale), round(frame.height * scale)
    frame = frame.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(frame, ((SIZE - w) // 2, (SIZE - h) // 2), frame)
    canvas.save(OUT)
    print(f"saved {OUT} {canvas.size}")


if __name__ == "__main__":
    main()
