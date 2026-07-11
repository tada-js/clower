#!/usr/bin/env python3
"""스프라이트 시트(raw/*.png) → 메뉴바용 프레임(frames/{name}_{i}.png).

각 시트를 흰 배경 간격으로 프레임 단위로 자르고, 흰 배경만 투명 처리한다.
원색(초록 줄기, 빨간 열매, 주황 화분 등)은 그대로 유지 — 컬러 아이콘이라
macOS 템플릿(isTemplate)을 쓰지 않는다. 프레임 개수는 자동 감지(흰 여백
열로 구분).

사용법: python3 slice.py   (raw/ 안의 모든 png 처리)
"""
import os
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
OUT = os.path.join(HERE, "frames")

# 흰 배경 판정: 이 값보다 어두운 채널이 하나라도 있으면 "잉크"(내용물).
WHITE_MIN = 245
# 알파 램프 구간: min(r,g,b)가 이 값 이하면 완전 불투명(원색 보존).
# 이 값~WHITE_MIN 사이에서만 선형으로 투명해진다 (안티에일리어싱 가장자리).
OPAQUE_MAX = 200
TARGET_H = 48       # 저장 높이(px). 앱에서 ~18pt로 축소(레티나 여유).


def min_channel(p):
    return min(p[0], p[1], p[2])


def column_has_ink(px, w, h, x):
    for y in range(h):
        if min_channel(px[x, y]) < WHITE_MIN:
            return True
    return False


def find_frames(img):
    """흰 여백 열로 구분된 프레임들의 x구간 [(left,right),...] 반환."""
    w, h = img.size
    px = img.load()
    inked = [column_has_ink(px, w, h, x) for x in range(w)]
    spans, start = [], None
    for x, has in enumerate(inked):
        if has and start is None:
            start = x
        elif not has and start is not None:
            spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, w))
    return spans


def content_band(img):
    """시트 전체에서 잉크가 있는 세로 범위 (top, bottom)."""
    w, h = img.size
    px = img.load()
    top, bot = None, None
    for y in range(h):
        row = any(min_channel(px[x, y]) < WHITE_MIN for x in range(w))
        if row:
            if top is None:
                top = y
            bot = y
    return top, bot + 1


def normalize(frame):
    """흰 배경만 투명 처리, 원색은 완전 불투명으로 유지.
    min(r,g,b) <= OPAQUE_MAX: 알파 255 (진한 색은 절대 희석 안 됨).
    OPAQUE_MAX~WHITE_MIN 사이: 선형 램프 (부드러운 가장자리).
    WHITE_MIN 이상(거의 흰색): 알파 0."""
    frame = frame.convert("RGBA")
    px = frame.load()
    w, h = frame.size
    span = max(1, WHITE_MIN - OPAQUE_MAX)
    for y in range(h):
        for x in range(w):
            r, g, b, _ = px[x, y]
            d = min(r, g, b)
            if d <= OPAQUE_MAX:
                a = 255
            elif d >= WHITE_MIN:
                a = 0
            else:
                a = round(255 * (WHITE_MIN - d) / span)
            px[x, y] = (r, g, b, a)
    return frame


def process(path, name):
    img = Image.open(path).convert("RGBA")
    spans = find_frames(img)
    top, bot = content_band(img)
    out = []
    for i, (l, r) in enumerate(spans):
        frame = img.crop((l, top, r, bot))
        frame = normalize(frame)
        scale = TARGET_H / frame.height
        frame = frame.resize((max(1, round(frame.width * scale)), TARGET_H), Image.LANCZOS)
        dest = os.path.join(OUT, f"{name}_{i}.png")
        frame.save(dest)
        out.append((f"{name}_{i}.png", frame.width, frame.height))
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    if not os.path.isdir(RAW):
        print("raw/ 없음", file=sys.stderr)
        sys.exit(1)
    total = 0
    for f in sorted(os.listdir(RAW)):
        if not f.endswith(".png"):
            continue
        name = os.path.splitext(f)[0]
        frames = process(os.path.join(RAW, f), name)
        print(f"{f}: {len(frames)}프레임 -> " + ", ".join(f"{n}({w}x{h})" for n, w, h in frames))
        total += len(frames)
    print(f"총 {total}프레임 저장: {OUT}")


if __name__ == "__main__":
    main()
