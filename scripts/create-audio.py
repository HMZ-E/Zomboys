#!/usr/bin/env python3
"""Original effects plus a reproducible clean, public-domain GAU-8 burst with its decay."""
from pathlib import Path
import array
import math
import random
import shutil
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Zomboys/Resources/Audio'
OUT.mkdir(parents=True, exist_ok=True)
SR = 22050


def write(name, values, peak=.92, edge_fade=True):
    values = list(values)
    if edge_fade:
        # Remove endpoint steps without truncating the report's natural decay.
        attack, release = min(int(SR * .003), len(values)), min(int(SR * .09), len(values))
        for i in range(attack):
            values[i] *= math.sin(math.pi * .5 * i / max(1, attack - 1)) ** 2
        for i in range(release):
            values[-release + i] *= math.cos(math.pi * .5 * i / max(1, release - 1)) ** 2
    scale = peak / max(1e-6, max(abs(v) for v in values))
    samples = array.array('h', (int(max(-.98, min(.98, v * scale)) * 32767) for v in values))
    with wave.open(str(OUT / (name + '.wav')), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(SR)
        audio.writeframes(samples.tobytes())


def weapon(name, duration, bass, decay, seed, metal=1, report=1):
    """Crack, low report, reflected tail and action mechanism; no sampled gun recordings."""
    rng = random.Random(seed)
    samples = []
    low = 0
    for i in range(int(SR * duration)):
        t = i / SR
        noise = rng.uniform(-1, 1)
        low = .8 * low + .2 * noise
        attack = min(1, t / .001)
        crack = .8 * noise * math.exp(-t * (62 + metal * 9))
        body = (.6 * low + .65 * math.sin(2 * math.pi * (bass * t - 35 * t * t))) * math.exp(-t * decay)
        reflections = 0
        for delay, strength in [(0.043, .2), (.084, .12), (.137, .06)]:
            q = t - delay
            if q >= 0:
                reflections += strength * noise * math.exp(-q * 35)
        # Separate chamber / bolt transient makes the slow sniper report distinguishable.
        bolt_time = .2 if duration > .7 else .09
        q = t - bolt_time
        bolt = .14 * metal * noise * math.exp(-q * 70) if q >= 0 else 0
        samples.append(attack * (crack + body * report + reflections + bolt))
    write(name, samples)


# A deployment gets a stable voice; these are different envelopes and timbres, not aliases.
for index, (bass, decay, metal, report) in enumerate([(155, 19, .65, .7), (185, 22, 1.3, .6), (125, 16, .9, 1), (215, 24, 1.6, .55)]):
    weapon(f'rifle_{index}', .42, bass, decay, 1000 + index, metal, report)
for index, (bass, decay, metal, report) in enumerate([(95, 6, 1.3, 1.1), (118, 8, 1.8, .9), (78, 5, .8, 1.35), (140, 10, 2.2, .8)]):
    weapon(f'sniper_{index}', 1.05, bass, decay, 2000 + index, metal, report)
shutil.copy(OUT / 'rifle_0.wav', OUT / 'rifle.wav')
weapon('heavy_gun', .7, 100, 11, 301)
weapon('mortar_launch', 1.15, 66, 6.5, 302, .55, 1.3)
weapon('cannon30', .95, 88, 7, 303, .8, 1.1)
weapon('cannon105', 2, 48, 2.8, 304, .65, 1.7)
weapon('barrier_hit', .3, 240, 16, 305, 2, .2)
weapon('bomb_release', .35, 320, 19, 306, 2.2, .2)


def explosion():
    rng = random.Random(400)
    samples = []
    low = 0
    for i in range(int(SR * 3.6)):
        t = i / SR
        noise = rng.uniform(-1, 1)
        low = .965 * low + .035 * noise
        attack = min(1, t / .0018)
        pressure = .72 * math.sin(2 * math.pi * (42 * t - 3.5 * t * t)) * math.exp(-t * 3)
        roar = (1.1 * low + .32 * noise * math.exp(-t * 6)) * math.exp(-t * 1.7)
        debris = noise * .055 * math.exp(-max(0, t - .27) * 1.5) * min(1, t / .27)
        samples.append(attack * (pressure + roar + debris))
    write('explosion', samples, .96)


def engine(name, seconds, style):
    rng = random.Random({'humvee': 501, 'prop': 502, 'a10': 503, 'b2': 504}[style])
    count = int(SR * seconds)
    white = [rng.uniform(-1, 1) for _ in range(count)]
    low = 0
    # Warm the filter with one complete loop: the low-frequency seam reaches steady state.
    for noise in white:
        low = .96 * low + .04 * noise
    samples = []
    for i, noise in enumerate(white):
        t = i / SR
        low = .96 * low + .04 * noise
        if style == 'humvee':
            value = .6 * low + .23 * math.sin(2 * math.pi * 35 * t) + .13 * math.sin(2 * math.pi * 70 * t) + .07 * math.sin(2 * math.pi * 140 * t)
        elif style == 'prop':
            # Four propellers: steady blade-pass pulses with slowly beating harmonics.
            pulse = sum(math.sin(2 * math.pi * hz * t) for hz in (52, 52.25, 104, 104.5)) / 4
            value = .17 * pulse + .5 * low + .018 * noise
        elif style == 'a10':
            value = .08 * noise + .7 * low + .075 * math.sin(2 * math.pi * 110 * t) + .018 * math.sin(2 * math.pi * 880 * t)
        elif style == 'b2':
            value = .026 * noise + .9 * low + .09 * math.sin(2 * math.pi * 40 * t) + .045 * math.sin(2 * math.pi * 80 * t)
        samples.append(value)
    # No recurring fade-to-silence: all pitched frequencies complete whole cycles.
    write(name, samples, .45, edge_fade=False)


def bomb_fall():
    rng = random.Random(601)
    low = 0
    samples = []
    for i in range(SR * 2):
        t = i / SR
        noise = rng.uniform(-1, 1)
        low = .85 * low + .15 * noise
        # A continuous air rush plus a narrow whistle; runtime pitch follows the actual fall.
        samples.append(.13 * low + .035 * noise + .11 * math.sin(2 * math.pi * 820 * t) + .035 * math.sin(2 * math.pi * 1640 * t))
    write('bomb_fall', samples, .36, edge_fade=False)


def tones(name, notes):
    samples = []
    for hz, duration in notes:
        for i in range(int(SR * duration)):
            t = i / SR
            env = max(0, min(1, t / .01, (duration - t) / .08))
            samples.append(.23 * env * math.sin(2 * math.pi * hz * t))
    write(name, samples, .3)


explosion()
engine('humvee_engine', 4, 'humvee')
engine('ac130_engine', 4, 'prop')
engine('a10_engine', 4, 'a10')
engine('b2_engine', 4, 'b2')
bomb_fall()
tones('warning', [(460, .23), (660, .23), (460, .23), (660, .35)])
tones('rescue', [(620, .1), (820, .16)])
tones('unit_lost', [(320, .15), (190, .35)])
tones('victory', [(440, .2), (550, .2), (660, .2), (880, .6)])
tones('defeat', [(390, .3), (330, .3), (220, .7)])

# The PCM is the development-only 22.05 kHz mono s16 decode of the credited DVIDS video.
# If it is absent, retain the checked-in, offline GAU-8 asset unchanged.
source = ROOT / '.build/a10.pcm'
if source.exists():
    recording = array.array('h')
    recording.frombytes(source.read_bytes())
    start, end = 63.80, 66.72
    gun = [sample / 32768 for sample in recording[int(start * SR):int(end * SR)]]
    # Gentle high-pass removes distant wind/DC while retaining the cannon report.
    filtered, last_input, last_output = [], 0, 0
    alpha = math.exp(-2 * math.pi * 28 / SR)
    for value in gun:
        last_output = alpha * (last_output + value - last_input)
        last_input = value
        filtered.append(last_output)
    # The source includes the complete report and ~1.2 seconds of its acoustic decay.
    # Fade the remaining very quiet location noise, rather than cutting it at a frame edge.
    tail = int(SR * .65)
    for i in range(tail):
        filtered[-tail + i] *= math.cos(math.pi * .5 * i / (tail - 1)) ** 2
    filtered.extend([0] * int(SR * .16))
    write('a10_brrrt', filtered, .9)

# Crowd voices and the continuous city drone are deliberately absent from this mix.
for obsolete in ('city_ambience.wav', 'zombie_groan.wav', 'zombie_attack.wav', 'civilian_scream.mp3'):
    (OUT / obsolete).unlink(missing_ok=True)
print('Combat effects generated; GAU-8 has a complete decay. City drone and crowd voices removed.')
