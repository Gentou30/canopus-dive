#!/usr/bin/env python3
"""水中の BGM・ジングル・効果音を合成して assets/audio/ に WAV で書き出す。外部素材なし。

前作（こんこん花札道中）で「BGM がチープ」と言われたので、
  - ゆっくり立ち上がるパッド（少しずつ音程をずらしたのこぎり波を重ねて丸める）で和音を厚くする
  - マリンバ・カリンバ・ハープ・チェレスタのような、残響に溶ける柔らかい音色を使う
  - ステレオで左右に広げ、深めのホール残響をかける。深い階ほど暗く、ゆっくり、静かにする
ループ再生するので、曲の終わりからはみ出した音と残響は頭に回り込ませる。

使い方: python3 tools/make_music.py → godot --headless --import
"""
import os
import wave

import numpy as np
from scipy import signal

SR = 32000
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")
rng = np.random.default_rng(5)

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def freq(name):
    n = NOTE[name[0]]
    rest = name[1:]
    if rest[0] == "#":
        n += 1
        rest = rest[1:]
    elif rest[0] == "b":
        n -= 1
        rest = rest[1:]
    return 440.0 * 2 ** ((12 * (int(rest) + 1) + n - 69) / 12)


def tr(name, semis):
    """音名を半音ずらした周波数"""
    return freq(name) * 2 ** (semis / 12)


def env_adsr(n, a=0.005, d=0.1, s=0.7, r=0.05):
    t = np.arange(n) / SR
    dur = n / SR
    e = np.where(t < a, t / max(a, 1e-6), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-6)))
    rel = np.clip((dur - t) / max(r, 1e-6), 0, 1)
    return e * rel


def bandpass(x, lo, hi, order=2):
    sos = signal.butter(order, [lo, min(hi, SR / 2 - 100)], "bandpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def lowpass(x, fc, order=2):
    sos = signal.butter(order, min(fc, SR / 2 - 100), "lowpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def highpass(x, fc, order=2):
    sos = signal.butter(order, fc, "highpass", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def peak(x, f0, q, gain):
    """f0 付近を持ち上げる（胴の響き）"""
    b, a = signal.iirpeak(f0, q, fs=SR)
    return x + gain * signal.lfilter(b, a, x)



def ks(f, dur, damp=0.996, bright=0.6, pick=0.2):
    n = int(dur * SR)
    D = max(2, int(SR / f - 0.5))
    exc = rng.uniform(-1, 1, D)
    # 明るさ：最初のノイズを丸める
    exc = signal.lfilter([1 - (1 - bright) * 0.9], [1, -(1 - bright) * 0.9], exc)
    # はじく位置：櫛形フィルタで倍音の抜けを作る
    k = max(1, int(D * pick))
    exc = exc - np.roll(exc, k)
    x = np.zeros(n)
    x[:min(D, n)] = exc[:min(D, n)]
    a = np.zeros(D + 2)
    a[0] = 1
    a[D] = -damp * 0.5
    a[D + 1] = -damp * 0.5
    y = signal.lfilter([1], a, x)
    return y / (np.max(np.abs(y)) + 1e-9)



def bell(f=880, dur=2.5, vel=1.0):
    """お寺の鐘のような長い金属音"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    x = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d)
            for r, a, d in [(1, 1, 1.2), (2.0, 0.5, 2), (2.76, 0.45, 2.5), (5.4, 0.25, 4), (8.9, 0.12, 6)])
    return x * 0.18 * vel



class Song:
    def __init__(self, bpm, bars, beats_per_bar=4):
        self.beat = 60 / bpm
        self.n = int(bars * beats_per_bar * self.beat * SR)
        self.dry = np.zeros((2, self.n))
        self.send = np.zeros((2, self.n))

    def at(self, beats):
        return beats * self.beat

    def add(self, x, beats, pan=0.0, rev=0.25, vol=1.0, human=True):
        """x を beats 拍目に置く。pan: -1 左〜1 右、rev: 残響に送る量。はみ出しは頭に回り込む"""
        t = self.at(beats)
        if human:
            t += rng.normal(0, 0.006)
            vol *= rng.uniform(0.9, 1.05)
        i = int(t * SR) % self.n
        l = np.cos((pan + 1) * np.pi / 4) * vol
        r = np.sin((pan + 1) * np.pi / 4) * vol
        # 曲の長さを超える分は頭へ回す
        pos = 0
        while pos < len(x):
            j = (i + pos) % self.n
            m = min(len(x) - pos, self.n - j)
            seg = x[pos:pos + m]
            for ch, g in ((0, l), (1, r)):
                self.dry[ch, j:j + m] += seg * g
                self.send[ch, j:j + m] += seg * g * rev
            pos += m

    def line(self, inst, notes, start, pan=0.0, rev=0.3, vol=1.0, legato=1.05, semis=0):
        """notes: "D5:1 E5:.5 -:1 ..."（- は休み）"""
        b = start
        for tok in notes.split():
            nm, ln = tok.split(":")
            ln = float(ln)
            if nm != "-":
                self.add(inst(tr(nm, semis), ln * self.beat * legato + 0.05), b, pan, rev, vol)
            b += ln
        return b


def hall_ir(sec=2.2, rt60=1.8, bright=0.5):
    """ホールの残響の応答（左右で別のノイズ。高い音ほど早く消える）"""
    n = int(sec * SR)
    t = np.arange(n) / SR
    out = []
    for ch in range(2):
        lo = lowpass(rng.normal(0, 1, n), 1500) * np.exp(-6.9 * t / rt60)
        hi = highpass(rng.normal(0, 1, n), 1500) * np.exp(-6.9 * t / (rt60 * 0.45)) * bright
        ir = lo + hi
        ir[: int(0.012 * SR)] = 0  # 直接音のあとに少し間をあける
        # 初期反射
        for d, g in ((0.017, 0.5), (0.023, 0.35), (0.031, 0.3), (0.043, 0.22)):
            ir[int((d + ch * 0.003) * SR)] += g * 4
        out.append(ir / np.sqrt(np.sum(ir ** 2)))
    return out


def master(song, wet=0.35, rt60=1.8):
    n = song.n
    ir = hall_ir(min(rt60 + 0.6, n / SR - 0.1), rt60)
    mix = song.dry.copy()
    for ch in range(2):
        w = signal.fftconvolve(song.send[ch], ir[ch])
        # ループの頭に残響の尾を回り込ませる
        full = np.zeros(n)
        for k in range(0, len(w), n):
            seg = w[k:k + n]
            full[:len(seg)] += seg
        mix[ch] += full * wet * 1.3
    mix = np.array([highpass(m, 35) for m in mix])
    pk = np.max(np.abs(mix)) + 1e-9
    mix = mix / pk * 1.5
    mix = np.tanh(mix) / np.tanh(1.5)  # やわらかく頭を抑える
    return mix


def save(name, stereo, peak=0.9):
    x = stereo / (np.max(np.abs(stereo)) + 1e-9) * peak
    data = (x.T * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{name}.wav  {x.shape[1] / SR:.1f}s")




# ───────── 音色 ─────────

def marimba(f, dur, vel=1.0):
    """木の板をたたく音：基音と、4倍近くの倍音がすぐ消える"""
    n = int(max(dur, 0.6) * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t) * np.exp(-t * 3.2)
    x += 0.35 * np.sin(2 * np.pi * f * 3.93 * t) * np.exp(-t * 14)
    x += 0.12 * np.sin(2 * np.pi * f * 9.2 * t) * np.exp(-t * 30)
    x[: int(0.002 * SR)] *= np.linspace(0, 1, int(0.002 * SR))
    return x * 0.35 * vel


def kalimba(f, dur, vel=1.0):
    """親指ピアノ：金属の舌の澄んだ音と、少しのうなり"""
    n = int(max(dur, 0.8) * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t) * np.exp(-t * 2.2)
    x += 0.25 * np.sin(2 * np.pi * f * 5.4 * t) * np.exp(-t * 18)
    x += 0.5 * np.sin(2 * np.pi * f * 1.003 * t) * np.exp(-t * 2.6)
    x[: int(0.003 * SR)] *= np.linspace(0, 1, int(0.003 * SR))
    return x * 0.28 * vel


def harp(f, dur, vel=1.0):
    x = ks(f, max(dur, 1.2), damp=0.9985, bright=0.45, pick=0.3)
    return lowpass(x, 3500) * 0.3 * vel


def celesta(f, dur, vel=1.0):
    n = int(max(dur, 1.0) * SR)
    t = np.arange(n) / SR
    x = sum(a * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d) for r, a, d in [(1, 1, 2.5), (2, 0.4, 4), (3.01, 0.2, 7), (4.2, 0.1, 10)])
    x[: int(0.002 * SR)] *= np.linspace(0, 1, int(0.002 * SR))
    return x * 0.22 * vel


def pad(fs_list, dur, vel=1.0, bright=1800, attack=0.6):
    """少しずつずらしたのこぎり波を重ねて丸めた、ゆっくり立ち上がる和音"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for f in fs_list:
        for det in (-0.006, 0.0, 0.0065):
            ph = rng.uniform(0, 1)
            ff = f * (1 + det)
            # 帯域を制限したのこぎり波（倍音を8つまで）
            for k in range(1, 9):
                if ff * k > SR / 2 - 500:
                    break
                x += np.sin(2 * np.pi * (ff * k * t + ph * k)) / k * (0.85 ** k)
    x = highpass(lowpass(x, bright, 2), 160)
    # ゆっくり明るさが揺れる（水の中のうねり）
    lfo = 0.85 + 0.15 * np.sin(2 * np.pi * 0.25 * t + rng.uniform(0, 6))
    e = env_adsr(n, attack, 0.8, 0.85, min(1.2, dur * 0.4))
    return x * e * lfo * 0.05 * vel / max(1, len(fs_list)) * 3


def sub_bass(f, dur, vel=1.0):
    n = int(dur * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * 2 * f * t) + 0.1 * np.sin(2 * np.pi * 3 * f * t)
    return x * env_adsr(n, 0.02, 0.3, 0.75, 0.12) * 0.17 * vel


def flute(f, dur, vel=1.0):
    """やわらかい笛（オカリナ寄り）。息の音とビブラート"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    vib = 1 + 0.008 * np.sin(2 * np.pi * 5.2 * t) * np.clip(t / 0.3, 0, 1)
    ph = np.cumsum(f * vib) / SR
    x = np.sin(2 * np.pi * ph) + 0.18 * np.sin(4 * np.pi * ph) + 0.05 * np.sin(6 * np.pi * ph)
    breath = bandpass(rng.normal(0, 1, n), f * 0.8, f * 3) * 0.06
    return (x + breath) * env_adsr(n, 0.06, 0.3, 0.85, 0.12) * 0.2 * vel


def shaker(vel=1.0):
    n = int(0.09 * SR)
    t = np.arange(n) / SR
    x = highpass(rng.normal(0, 1, n), 5000) * np.exp(-t * 45) * np.clip(t / 0.01, 0, 1)
    return x * 0.12 * vel


def kick(vel=1.0):
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    f = 50 + 70 * np.exp(-t * 30)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)
    return x * 0.5 * vel


def wood(vel=1.0):
    n = int(0.1 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 900 * t) * np.exp(-t * 60) + 0.3 * np.sin(2 * np.pi * 2300 * t) * np.exp(-t * 90)
    return x * 0.18 * vel


def drop(vel=1.0, f0=700):
    """水滴：音程がすっと上がる短い音"""
    n = int(0.18 * SR)
    t = np.arange(n) / SR
    f = f0 * (1 + 2.5 * t / 0.18)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 25)
    return x * 0.2 * vel


def perc(song, pattern, bars, start_bar=0, vol=1.0):
    """1小節16文字。K キック s シェイカー S 強いシェイカー w 木の音 d 水滴"""
    for bar in range(start_bar, start_bar + bars):
        for i, ch in enumerate(pattern):
            b = bar * 4 + i / 4
            if ch == "K":
                song.add(kick(), b, 0, 0.05, vol)
            elif ch == "s":
                song.add(shaker(0.6), b, 0.35, 0.1, vol)
            elif ch == "S":
                song.add(shaker(1.0), b, 0.35, 0.1, vol)
            elif ch == "w":
                song.add(wood(), b, -0.3, 0.2, vol)
            elif ch == "d":
                song.add(drop(1.0, rng.uniform(500, 1100)), b, rng.uniform(-0.7, 0.7), 0.6, vol)


def chord_names(s):
    return [[freq(n) for n in c.split()] for c in s.split("|")]


def pads(song, chs, start_bar, bars_each=1, vol=1.0, bright=1800, pan=0.0):
    for i, c in enumerate(chs):
        song.add(pad(c, bars_each * 4 * song.beat + 0.8, vol, bright), (start_bar + i * bars_each) * 4, pan, 0.6, 1.0, human=False)


def arps(song, inst, chs, start_bar, pattern, step=0.5, vol=1.0, pan=0.0, rev=0.4, octave=1.0):
    """和音の音を pattern の順にはじく（pattern は和音の何番目かの並び）"""
    for i, c in enumerate(chs):
        for j, k in enumerate(pattern):
            f = c[k % len(c)] * octave * (2 if k >= len(c) else 1)
            song.add(inst(f, step * song.beat * 2), (start_bar + i) * 4 + j * step, pan, rev, vol)


def bass_roots(song, roots, start_bar, beats=(0, 2.5), vol=1.0, dur=1.6):
    for i, r in enumerate(roots):
        for b in beats:
            song.add(sub_bass(freq(r), dur * song.beat), (start_bar + i) * 4 + b, 0, 0.05, vol)


# ───────── 曲 ─────────

def bgm_title():
    """タイトル：わくわくする出発。D メジャー・96BPM・16小節"""
    s = Song(96, 16)
    chs = chord_names("D4 F#4 A4 C#5|B3 D4 F#4 A4|G3 B3 D4 F#4|A3 C#4 E4 G4|"
                      "D4 F#4 A4 C#5|F#3 A3 C#4 E4|G3 B3 D4 F#4|A3 C#4 E4 A4")
    for rep in range(2):
        pads(s, chs, rep * 8, vol=0.8)
        arps(s, harp, chs, rep * 8, [0, 1, 2, 3, 2, 1, 2, 3], 0.5, 0.5, -0.4)
        bass_roots(s, ["D2", "B1", "G1", "A1", "D2", "F#2", "G2", "A2"], rep * 8, (0, 1.5, 2.5), 0.9, 0.9)
    perc(s, "K-s-s-sSK-s-wsSs", 14, 2, 0.8)
    mel = ("A5:1.5 F#5:.5 E5:1 D5:1 | E5:1.5 F#5:.5 A5:2 | B5:1 A5:.5 F#5:.5 D5:1 E5:1 | C#5:3 -:1 | "
           "A5:1.5 F#5:.5 E5:1 D5:1 | C#5:1 E5:1 A5:1 G#5:1 | B5:1.5 A5:.5 F#5:1 B5:1 | A5:3 -:1")
    s.line(marimba, mel.replace("|", ""), 0, 0.2, 0.35, 1.0)
    mel2 = ("D6:1 C#6:.5 B5:.5 A5:1 F#5:1 | G5:1 A5:1 B5:2 | A5:1 F#5:.5 E5:.5 D5:1 B4:1 | C#5:2 E5:2 | "
            "F#5:1 A5:1 D6:1.5 C#6:.5 | B5:1 A5:1 G#5:2 | G5:1 F#5:1 E5:1 G5:1 | F#5:2 E5:1 -:1")
    s.line(flute, mel2.replace("|", ""), 32, -0.15, 0.45, 0.9)
    s.line(celesta, mel2.replace("|", ""), 32, 0.4, 0.5, 0.35)
    return master(s, 0.4, 2.4)


def bgm_shallow():
    """浅瀬：日の差すさんご礁。C リディア（明るく少し不思議）・100BPM・16小節"""
    s = Song(100, 16)
    chs = chord_names("C4 E4 G4 B4|D4 F#4 A4 C5|A3 C4 E4 G4|G3 B3 D4 F#4|"
                      "F3 A3 C4 E4|D4 F#4 A4 C5|E4 G4 B4 D5|A3 C4 E4 G4")
    roots = ["C2", "D2", "A1", "G1", "F1", "D2", "E2", "A1"]
    for rep in range(2):
        pads(s, chs, rep * 8, vol=0.7, bright=2400)
        arps(s, kalimba, chs, rep * 8, [0, 2, 1, 3, 2, 4, 3, 2], 0.5, 0.45, 0.45)
        bass_roots(s, roots, rep * 8, (0, 1.5, 3), 0.85, 0.8)
    perc(s, "K-s-wSs-K-sswSs-", 16, 0, 0.75)
    perc(s, "-------d--------", 8, 8, 0.8)
    mel = ("E5:1 G5:.5 A5:.5 B5:1.5 A5:.5 | F#5:1 A5:1 D6:2 | C6:1 B5:.5 A5:.5 G5:1 E5:1 | F#5:3 -:1 | "
           "A5:1 G5:.5 F#5:.5 E5:1 C5:1 | D5:1 F#5:1 A5:2 | B5:1 G5:.5 E5:.5 D5:1 B4:1 | E5:3 -:1")
    s.line(marimba, mel.replace("|", ""), 0, -0.1, 0.35, 1.0)
    mel2 = ("G5:2 E5:1 G5:1 | A5:2 F#5:2 | E5:1.5 G5:.5 C6:2 | B5:3 -:1 | "
            "C6:1 B5:1 A5:1 G5:1 | F#5:1.5 E5:.5 D5:2 | E5:1 G5:1 B5:1 D6:1 | C6:2 B5:1 -:1")
    s.line(flute, mel2.replace("|", ""), 32, 0.2, 0.45, 0.85)
    s.line(marimba, mel2.replace("|", ""), 32, -0.3, 0.35, 0.4, semis=-12)
    return master(s, 0.45, 2.6)


def bgm_mid():
    """中層：しずんだ遺跡。D ドリア（ほの暗い）・84BPM・16小節"""
    s = Song(84, 16)
    chs = chord_names("D3 A3 C4 F4|C3 G3 Bb3 E4|Bb2 F3 A3 D4|C3 G3 B3 E4|"
                      "D3 A3 C4 F4|F3 C4 E4 A4|G3 D4 F4 B4|A3 E4 G4 C#5")
    roots = ["D2", "C2", "Bb1", "C2", "D2", "F2", "G1", "A1"]
    for rep in range(2):
        pads(s, chs, rep * 8, vol=0.9, bright=1400)
        arps(s, harp, chs, rep * 8, [0, 1, 2, 3, 4, 3, 2, 1], 0.5, 0.5, -0.45, octave=2)
        bass_roots(s, roots, rep * 8, (0, 2.5), 0.9, 2.2)
    perc(s, "K-------w--K----", 16, 0, 0.6)
    perc(s, "----d-------d---", 16, 0, 0.6)
    mel = ("A5:2 G5:1 F5:1 | E5:2 C5:2 | D5:1.5 E5:.5 F5:1 A5:1 | G5:3 -:1 | "
           "A5:2 C6:1 A5:1 | G5:1.5 F5:.5 E5:2 | F5:1 D5:1 G5:1.5 F5:.5 | E5:3 -:1")
    s.line(flute, mel.replace("|", ""), 0, 0.2, 0.5, 0.9)
    s.line(celesta, ("D6:4 C6:4 Bb5:4 B5:4 D6:4 C6:4 B5:4 C#6:4"), 32, 0.45, 0.6, 0.5)
    mel2 = ("D6:1 C6:1 A5:2 | G5:1 A5:1 E5:2 | F5:1 G5:1 A5:1 D6:1 | B5:3 -:1 | "
            "C6:1 A5:1 F5:1 A5:1 | G5:2 E5:2 | F5:1.5 G5:.5 A5:1 B5:1 | C#6:3 -:1")
    s.line(flute, mel2.replace("|", ""), 32, 0.2, 0.5, 0.8)
    return master(s, 0.55, 3.0)


def bgm_deep():
    """深海：星の眠る底。音数を減らし、低い和音と光る粒のような高い音。62BPM・12小節"""
    s = Song(62, 12)
    chs = chord_names("E3 B3 D4 G4|C3 G3 B3 E4|A2 E3 G3 C4|B2 F#3 A3 D#4|"
                      "E3 B3 D4 G4|C3 G3 B3 F#4")
    roots = ["E1", "C1", "A1", "B1", "E1", "C1"]
    pads(s, chs + chs, 0, 2 // 2, 1.0, 900)
    for i, r in enumerate(roots + roots):
        s.add(sub_bass(freq(r), 4 * s.beat), i * 4, 0, 0.05, 0.8)
    # 光る粒：ばらばらの高い音
    notes = ["E6", "G6", "B6", "D6", "F#6", "B5", "E6", "A6"]
    for k in range(30):
        b = rng.uniform(0, 48)
        s.add(celesta(freq(notes[k % len(notes)]), 1.5, 0.45), b, rng.uniform(-0.8, 0.8), 0.8, 0.6)
    perc(s, "--------d-------", 12, 0, 0.5)
    mel = "B5:3 A5:1 G5:2 E5:2 | -:4 | E5:2 G5:2 F#5:4 | -:4 | B5:2 D6:2 C6:3 B5:1 | A5:4 | -:4 | F#5:4"
    s.line(flute, mel.replace("|", ""), 16, 0.25, 0.6, 0.55)
    return master(s, 0.7, 4.0)


def bgm_rest():
    """空気だまり：ひと休み。オルゴールのようなチェレスタ。72BPM・8小節"""
    s = Song(72, 8)
    chs = chord_names("F3 A3 C4 E4|G3 B3 D4 F#4|E3 G3 B3 D4|A3 C4 E4 G4|"
                      "D3 F3 A3 C4|G3 B3 D4 F4|C4 E4 G4 B4|C4 E4 G4 B4")
    pads(s, chs, 0, vol=0.8, bright=1600)
    bass_roots(s, ["F1", "G1", "E1", "A1", "D2", "G1", "C2", "C2"], 0, (0,), 0.7, 3.5)
    arps(s, harp, chs, 0, [0, 2, 3, 2], 1.0, 0.4, -0.4, octave=2)
    mel = "A5:1 C6:1 E6:1 D6:1 | B5:2 A5:1 G5:1 | E5:1 G5:1 B5:1 D6:1 | C6:3 -:1 | A5:1 G5:1 F5:1 A5:1 | G5:2 D5:2 | E5:1 G5:1 B5:1 C6:1 | B5:4"
    s.line(celesta, mel.replace("|", ""), 0, 0.3, 0.5, 0.8)
    return master(s, 0.5, 2.8)


def bgm_boss():
    """海竜戦：星を守る竜。E マイナー・132BPM・16小節。マリンバの刻みと太い低音で急かす"""
    s = Song(132, 16)
    chs = chord_names("E3 B3 G4|C3 G3 E4|D3 A3 F#4|B2 F#3 D#4|"
                      "E3 B3 G4|A2 E3 C4|C3 G3 E4|B2 F#3 D#4")
    roots = ["E1", "C1", "D1", "B0", "E1", "A0", "C1", "B0"]
    for rep in range(2):
        pads(s, chs, rep * 8, vol=0.75, bright=2200)
        arps(s, marimba, chs, rep * 8, [0, 1, 2, 1, 0, 2, 1, 2], 0.5, 0.55, -0.3, octave=2)
        bass_roots(s, roots, rep * 8, (0, 1.5, 2.5, 3.5), 1.0, 0.45)
    perc(s, "K---s-K-K-s-K-sS", 16, 0, 0.9)
    perc(s, "----w-------w-w-", 16, 0, 0.5)
    mel = ("B5:1.5 A5:.5 G5:1 F#5:1 | E5:2 G5:2 | F#5:1 A5:1 D6:1.5 C6:.5 | B5:4 | "
           "B5:1 E6:1 D6:1 B5:1 | C6:2 A5:2 | G5:1 B5:1 E6:1.5 F#6:.5 | D#6:4")
    s.line(flute, mel.replace("|", ""), 32, 0.2, 0.4, 0.85)
    s.line(celesta, "E6:2 B6:2 E6:2 B6:2 D6:2 A6:2 F#6:2 D#6:2", 0, 0.45, 0.6, 0.45)
    return master(s, 0.35, 1.8)


def jingle(beats_len, bpm, build, wet=0.4, rt=2.2):
    s = Song(bpm, 1)
    s.n = int(beats_len * s.beat * SR)
    s.dry = np.zeros((2, s.n))
    s.send = np.zeros((2, s.n))
    build(s)
    # ジングルはループしないので、残響は回り込ませずに長めに伸ばす
    tail = int(rt * SR)
    s.dry = np.pad(s.dry, ((0, 0), (0, tail)))
    s.send = np.pad(s.send, ((0, 0), (0, tail)))
    s.n += tail
    return master(s, wet, rt)


def jingle_surface():
    def b(s):
        s.line(marimba, "D5:.5 F#5:.5 A5:.5 D6:1.5", 0, 0, 0.3, 1.0)
        s.line(celesta, "-:2 A6:1 D7:2", 0, 0.3, 0.5, 0.6)
        s.add(pad([freq("D4"), freq("F#4"), freq("A4")], 3 * s.beat, 1.0, 2400, 0.1), 2, 0, 0.6, 1.0)
        s.add(sub_bass(freq("D2"), 2.5 * s.beat), 2, 0, 0.05, 0.9)
    return jingle(6, 110, b)


def jingle_faint():
    def b(s):
        s.line(celesta, "E6:.75 C6:.75 A5:.75 F5:2", 0, 0.2, 0.5, 0.8)
        s.add(pad([freq("F3"), freq("Ab3"), freq("C4")], 3 * s.beat, 1.0, 900, 0.2), 1.5, 0, 0.7, 1.0)
    return jingle(6, 80, b, 0.6, 3.0)


def main():
    for name, fn in [("bgm_title", bgm_title), ("bgm_shallow", bgm_shallow), ("bgm_mid", bgm_mid),
                     ("bgm_deep", bgm_deep), ("bgm_rest", bgm_rest),
                     ("jingle_surface", jingle_surface), ("jingle_faint", jingle_faint), ("bgm_boss", bgm_boss)]:
        save(name, fn())


if __name__ == "__main__":
    main()
