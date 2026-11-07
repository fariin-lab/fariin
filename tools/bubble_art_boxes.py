"""Where each v2 picture style's corner art reaches INSIDE the bubble's outline, per corner.
usage: python -I tools/bubble_art_boxes.py <fariin-bubbles dir> [--json] [--debug outdir] [name ...]

Feeds the `corners` column of Kulan/Services/PictureStyles.swift. For every style it rebuilds the
plain body of the v2 picture (the same side profiles and rounded rect that the bubble set's
tools/round_v2.py drew it with) and calls every pixel that differs from that body "art". Only art
inside the outline counts: art above, beside or under the bubble never touches the words.

Each piece of art inside gives a box (corner, w, h) in picture px, corner = tl, tr, bl or br:
  w = how far the piece reaches in from that SIDE of the outline,
  h = how far it reaches in from that corner's TOP or BOTTOM edge.
No boxes means nothing inside. Thin lines hugging the frame are body, not art, and are skipped. The app keeps the words 4pt clear of that box, and only on the rows
the box covers, so a peeker sitting above the bubble costs no side room at all.
Art in the stretched middle of an edge is reported, and that part of it counts twice (it grows
with the bubble).
"""
import sys, json, os, glob
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

ROOT = os.path.abspath(sys.argv[1])
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import round_v2 as rv  # noqa: E402

V2 = os.path.join(ROOT, 'bubbles_v2')


def boxes(name, debug=None):
    a = np.asarray(Image.open(f'{V2}/{name}.webp').convert('RGBA')).astype(float)
    j = json.load(open(f'{V2}/{name}.json'))
    tw = rv.TWEAK.get(name, {})
    H, W = a.shape[:2]
    bt, br, bb, bl = j['bubble']
    bb = min(bb, H - 1); br = min(br, W - 1)
    box = (bt, br, bb, bl)
    R = j['radius']
    fill = rv.hexrgb(j['fill'])
    alpha = a[..., 3] > 128
    ap = a.copy(); ap[~alpha, :3] = fill
    maxd = int(min(70, (bb - bt) * .25))
    if 'stack' in tw:
        st = tw['stack']; dx, dy = st['dx'], st['dy']; line = rv.hexrgb(st['line']); w = st['w']

        def plain(face):
            p = np.tile(face, (maxd, 1)); p[:w] = line
            return {k: p.copy() for k in ('top', 'right', 'bottom', 'left')}
        back = rv.body(H, W, (bt + dy, br, bb, bl + dx), R, plain(rv.hexrgb(st['back'])), fill, rv.SS)
        new = rv.body(H, W, (bt, br - dx, bb - dy, bl), R, plain(fill), fill, rv.SS)
        a_ = new[..., 3:4]
        rgb_ = new[..., :3] * a_ + back[..., :3] * back[..., 3:4] * (1 - a_)
        al_ = a_ + back[..., 3:4] * (1 - a_)
        model = np.dstack([np.where(al_ > 0, rgb_ / np.maximum(al_, 1e-6), 0), al_])
    else:
        prof, depth = rv.side_profiles(ap, box, fill, maxd)
        for k, n in tw.get('depth', {}).items():
            prof[k][n:] = fill
        model = rv.body(H, W, box, R, prof, fill, rv.SS)
    diff = np.abs(a[..., :3] - model[..., :3]).sum(2) + np.abs(a[..., 3] - model[..., 3] * 255) * 3
    inside = rv.sdf(H, W, box, R) > 1.5          # inside the outline, past its anti-aliased edge
    art = inside & (diff > 90)
    art = ndi.binary_opening(art, iterations=1)   # resampling noise along the drawn frame
    lab, nl = ndi.label(art, structure=np.ones((3, 3)))
    if nl:
        sizes = ndi.sum(art, lab, range(1, nl + 1))
        art = np.isin(lab, [i + 1 for i, s in enumerate(sizes) if s >= 25])
    T, Rt, B, L = j['slice']
    lab, nl = ndi.label(art, structure=np.ones((3, 3)))
    found = []                                     # (corner, w, h) per piece of art
    warn = []
    for i, sl in enumerate(ndi.find_objects(lab)):
        ys, xs = np.nonzero(lab[sl] == i + 1)
        ys = ys + sl[0].start; xs = xs + sl[1].start
        bw, bh = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
        if min(bw, bh) <= 8 and max(bw, bh) >= 40:
            continue                               # a thin line along the frame: the body, not art
        cy, cx = ys.mean(), xs.mean()
        top = cy < H / 2; left = cx < W / 2
        mid = ~(((ys < T) | (ys >= H - B)) & ((xs < L) | (xs >= W - Rt)))
        if mid.any():
            warn.append((int(xs[mid][0]), int(ys[mid][0]), int(mid.sum())))
        # The part of a piece that lies in a stretched middle grows with the bubble: it counts
        # twice, which covers a bubble up to about twice the picture's own middle.
        if left:
            w = xs.max() - bl + 1 + max(0, xs.max() - L + 1)
        else:
            w = br - xs.min() + 1 + max(0, (W - Rt) - xs.min())
        if top:
            h = ys.max() - bt + 1 + max(0, ys.max() - T + 1)
        else:
            h = bb - ys.min() + 1 + max(0, (H - B) - ys.min())
        found.append((('t' if top else 'b') + ('l' if left else 'r'), int(w), int(h)))
    # a piece inside another piece's box (same corner) adds nothing
    out = []
    for c, w, h in sorted(set(found), key=lambda f: (f[0], -f[1] * f[2])):
        if not any(c == c2 and w <= w2 and h <= h2 for c2, w2, h2 in out):
            out.append((c, w, h))
    out.sort(key=lambda f: ('tl', 'tr', 'bl', 'br').index(f[0]))
    if debug:
        os.makedirs(debug, exist_ok=True)
        im = a.copy(); im[art] = [255, 0, 255, 255]
        Image.fromarray(im.clip(0, 255).astype(np.uint8), 'RGBA').save(f'{debug}/{name}.png')
    return out, warn


if __name__ == '__main__':
    args = sys.argv[2:]
    as_json = '--json' in args
    args = [x for x in args if x != '--json']
    debug = None
    if '--debug' in args:
        i = args.index('--debug'); debug = args[i + 1]; del args[i:i + 2]
    names = args or sorted(os.path.basename(p)[:-5] for p in glob.glob(f'{V2}/*.json'))
    res = {}
    for n in names:
        b, warn = boxes(n, debug)
        res[n] = b
        if not as_json:
            msg = f'  (in a stretched middle: {warn})' if warn else ''
            print(f'{n:11s} ' + ' '.join(f'{c}={w}x{h}' for c, w, h in b) + msg)
    if as_json:
        print(json.dumps(res))
