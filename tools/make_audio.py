#!/usr/bin/env python3
"""効果音を合成して assets/audio/sfx_*.wav に書き出す（BGM は make_music.py）。
ミラの鳴き声（きゅっ）は、音程が上下するやわらかい声のような音を、気持ちごとに音程の動きを変えて作る。

使い方: python3 tools/make_audio.py → godot --headless --import
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from make_music import (SR, bandpass, celesta, drop, env_adsr, freq, highpass, kalimba, lowpass,  # noqa: E402
                        marimba, rng, save as save_stereo)


def save(name, x, peak=0.8):
    x = np.asarray(x, dtype=float)
    save_stereo("sfx_" + name, np.vstack([x, x]), peak)


def at(buf, x, sec):
    i = int(sec * SR)
    m = min(len(x), len(buf) - i)
    buf[i:i + m] += x[:m]
    return buf


def silence(sec):
    return np.zeros(int(sec * SR))


def noise(sec):
    return rng.normal(0, 1, int(sec * SR))


def sweep(f0, f1, sec, decay=8.0, shape=1.0):
    n = int(sec * SR)
    t = np.arange(n) / SR
    f = f0 + (f1 - f0) * (t / sec) ** shape
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * decay)


def bubble(f0=500, sec=0.12):
    """ぽこっ：音程が急に上がる短い音"""
    n = int(sec * SR)
    t = np.arange(n) / SR
    f = f0 * (1 + 3 * (t / sec) ** 1.5)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 30) * np.clip(t / 0.003, 0, 1)


def voice(contour, sec, base=900, vib=0.0, breath=0.05):
    """ミラの声：基音＋倍音を口の形（フォルマント）で丸める。contour は 0〜1 の時間で音程の倍率を返す"""
    n = int(sec * SR)
    t = np.arange(n) / SR
    k = t / sec
    f = base * contour(k) * (1 + vib * np.sin(2 * np.pi * 9 * t))
    ph = np.cumsum(f) / SR
    x = np.sin(2 * np.pi * ph) + 0.5 * np.sin(4 * np.pi * ph) + 0.25 * np.sin(6 * np.pi * ph) + 0.1 * np.sin(8 * np.pi * ph)
    x = bandpass(x, 500, 4200)
    x += bandpass(noise(sec), 2000, 6000) * breath
    e = np.clip(t / 0.015, 0, 1) * np.clip((sec - t) / 0.06, 0, 1)
    return x * e


def main():
    # 画面
    save("click", bubble(700, 0.07) * 0.6)
    save("card", lowpass(bandpass(noise(0.08), 1500, 6000) * np.exp(-np.arange(int(0.08 * SR)) / SR * 50), 6000))
    save("talk", bubble(900, 0.05) * 0.5)
    save("get", at(at(silence(0.6), kalimba(freq("E6"), 0.5), 0), kalimba(freq("B6"), 0.5), 0.08))
    # 泳ぐ・潜る
    sw = bandpass(noise(0.35), 300, 1800) * np.sin(np.linspace(0, np.pi, int(0.35 * SR))) * 0.5
    for i in range(3):
        at(sw, bubble(rng.uniform(400, 800), 0.1) * 0.4, 0.08 + i * 0.07)
    save("swim", sw)
    dv = bandpass(noise(0.7), 200, 1200) * np.sin(np.linspace(0, np.pi, int(0.7 * SR))) * 0.6
    at(dv, sweep(500, 150, 0.6, 3) * 0.4, 0)
    save("dive", dv)
    wh = bandpass(noise(0.3), 600, 3000) * np.sin(np.linspace(0, np.pi, int(0.3 * SR)))
    save("whoosh", wh)
    bb = silence(0.5)
    for i in range(6):
        at(bb, bubble(rng.uniform(350, 900), 0.12), i * 0.06 + rng.uniform(0, 0.02))
    save("bubble", bb)
    # 宝
    co = silence(0.6)
    at(co, celesta(freq("B6"), 0.5, 1.0), 0)
    at(co, celesta(freq("E7"), 0.5, 0.9), 0.07)
    save("coin", co)
    ge = silence(1.2)
    for i, nm in enumerate(["E6", "G#6", "B6", "E7"]):
        at(ge, celesta(freq(nm), 0.9, 0.9), i * 0.06)
    save("gem", ge)
    st = silence(0.6)
    at(st, marimba(freq("C6"), 0.4), 0)
    at(st, marimba(freq("G6"), 0.4), 0.08)
    save("stash", st)
    # 音波：澄んだ「キュイーン」
    so = sweep(1800, 3200, 0.5, 4, 0.5) * 0.6 + sweep(3600, 6400, 0.5, 6, 0.5) * 0.15
    so = np.concatenate([so, silence(0.4)])
    echo = np.zeros_like(so)
    for d, g in ((0.18, 0.4), (0.36, 0.2)):
        echo[int(d * SR):] += so[:len(so) - int(d * SR)] * g
    save("sonar", so + echo)
    # 攻撃・ダメージ
    hit = lowpass(noise(0.15), 2500) * np.exp(-np.arange(int(0.15 * SR)) / SR * 30)
    at(hit, sweep(220, 80, 0.15, 20) * 1.2, 0)
    save("hit", hit)
    save("bump", sweep(160, 60, 0.12, 25) + lowpass(noise(0.12), 800) * 0.3 * np.exp(-np.arange(int(0.12 * SR)) / SR * 40))
    pop = bubble(300, 0.18) * 0.8
    pop = at(np.concatenate([pop, silence(0.3)]), bubble(700, 0.1) * 0.5, 0.1)
    save("pop", pop)
    hu = sweep(500, 180, 0.35, 6) + lowpass(noise(0.35), 1800) * 0.4 * np.exp(-np.arange(int(0.35 * SR)) / SR * 15)
    save("hurt", hu)
    bi = bandpass(noise(0.12), 800, 4000) * np.exp(-np.arange(int(0.12 * SR)) / SR * 35)
    bi = at(np.concatenate([bi, silence(0.1)]), sweep(400, 120, 0.1, 20) * 0.8, 0.02)
    save("bite", bi)
    zn = int(0.5 * SR)
    zap = np.sign(np.sin(2 * np.pi * np.cumsum(120 + 80 * rng.random(zn)) / SR)) * 0.3
    zap = bandpass(zap + noise(0.5) * 0.4, 600, 7000) * np.exp(-np.arange(zn) / SR * 5) * (0.6 + 0.4 * (rng.random(zn) > 0.5))
    save("zap", zap)
    bl = silence(0.7)
    for i, nm in enumerate(["A6", "E7"]):
        at(bl, celesta(freq(nm), 0.6, 1.0), i * 0.05)
    save("block", bl)
    al = silence(0.3)
    at(al, marimba(freq("A5"), 0.2), 0)
    at(al, marimba(freq("E6"), 0.2), 0.07)
    save("alert", al)
    dr = silence(0.9)
    for i in range(5):
        at(dr, bubble(rng.uniform(200, 400), 0.15) * (1 - i * 0.15), i * 0.13)
    save("drown", dr)
    # ミラの鳴き声
    save("mira_happy", np.concatenate([voice(lambda k: 1.0 + 0.5 * np.sin(np.pi * k), 0.16, 1000), silence(0.04),
                                       voice(lambda k: 1.2 + 0.4 * k, 0.2, 1000, 0.02)]))
    save("mira_q", voice(lambda k: 0.9 + 0.6 * k ** 2, 0.32, 950, 0.0))
    save("mira_sad", voice(lambda k: 1.0 - 0.35 * k, 0.5, 850, 0.03, 0.08) * 0.8)
    save("mira_alert", np.concatenate([voice(lambda k: 1.3 + 0.2 * k, 0.1, 1100), silence(0.03),
                                       voice(lambda k: 1.4 + 0.3 * k, 0.14, 1100)]))
    # ぺしっ（ミラが羽ではたく）
    sl = bandpass(noise(0.08), 1500, 7000) * np.exp(-np.arange(int(0.08 * SR)) / SR * 60)
    save("slap", sl)
    # 3版目：見つかった・ボス
    sp = silence(0.6)
    for i, nm in enumerate(["E5", "B5", "E6"]):
        at(sp, marimba(freq(nm), 0.25, 1.0), i * 0.06)
    at(sp, sweep(900, 1500, 0.3, 6) * 0.25, 0.15)
    save("spot", sp)
    wn = silence(0.7)
    for i in range(2):
        at(wn, sweep(330, 300, 0.22, 10) * 0.7 + sweep(660, 600, 0.22, 12) * 0.25, i * 0.28)
    save("warn", wn)
    rn = int(1.4 * SR)
    ro = lowpass(noise(1.4), 700) * np.sin(np.linspace(0, np.pi, rn)) ** 0.7
    ro = ro + sweep(140, 55, 1.4, 1.5) * 0.9 + sweep(280, 110, 1.4, 2.0) * 0.3
    save("roar", ro)
    bn = int(0.9 * SR)
    br = bandpass(noise(0.9), 400, 5000) * np.sin(np.linspace(0, np.pi, bn)) + sweep(1200, 300, 0.9, 2) * 0.3
    save("breath", br)
    sr = silence(1.8)
    for i, nm in enumerate(["E6", "B6", "E7", "G#7", "B7"]):
        at(sr, celesta(freq(nm), 1.2, 0.9), i * 0.09)
    save("star", sr)
    # お店：買った（コインがじゃらっ）／強化（きらりと上がる）
    by = silence(0.7)
    for i in range(5):
        at(by, celesta(freq(["B6", "E7", "G#6", "B6", "E7"][i]), 0.4, 0.6), i * 0.045 + rng.uniform(0, 0.015))
    at(by, kalimba(freq("E6"), 0.5) * 0.7, 0.22)
    save("buy", by)
    up = silence(1.0)
    at(up, sweep(600, 1800, 0.35, 1.5) * 0.25, 0)
    for i, nm in enumerate(["E6", "G#6", "B6", "E7"]):
        at(up, kalimba(freq(nm), 0.5) * 0.8, 0.1 + i * 0.07)
    save("upgrade", up)


if __name__ == "__main__":
    main()
